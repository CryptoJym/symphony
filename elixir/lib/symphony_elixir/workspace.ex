defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id),
           :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?),
           :ok <- write_issue_manifest(workspace, issue_or_identifier, issue_context) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id) do
      {:ok, workspace} -> remove(workspace)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          stderr_to_stdout: true,
          env: hook_env(issue_context)
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp write_issue_manifest(workspace, %{} = issue_or_identifier, issue_context) do
    symphony_dir = Path.join(workspace, ".symphony")
    manifest_path = Path.join(symphony_dir, "issue.json")

    manifest =
      issue_or_identifier
      |> issue_manifest(issue_context)
      |> json_safe()

    with :ok <- File.mkdir_p(symphony_dir),
         {:ok, encoded} <- Jason.encode(manifest, pretty: true),
         :ok <- File.write(manifest_path, encoded <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:issue_manifest_write_failed, reason}}
    end
  end

  defp write_issue_manifest(_workspace, _issue_or_identifier, _issue_context), do: :ok

  defp issue_manifest(%_{} = issue, issue_context) do
    issue
    |> Map.from_struct()
    |> Map.merge(issue_context)
  end

  defp issue_manifest(%{} = issue, issue_context), do: Map.merge(issue, issue_context)
  defp issue_manifest(_issue_or_identifier, issue_context), do: issue_context

  defp hook_env(issue_context) do
    [
      {"SYMPHONY_ISSUE_ID", issue_context.issue_id},
      {"SYMPHONY_ISSUE_IDENTIFIER", issue_context.issue_identifier},
      {"SYMPHONY_ISSUE_TITLE", Map.get(issue_context, :issue_title)},
      {"SYMPHONY_ISSUE_STATE", Map.get(issue_context, :issue_state)},
      {"SYMPHONY_ISSUE_URL", Map.get(issue_context, :issue_url)}
    ]
    |> Enum.map(fn {key, value} -> {key, env_value(value)} end)
  end

  defp env_value(nil), do: ""
  defp env_value(value), do: to_string(value)

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value), do: Time.to_iso8601(value)
  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()
  defp json_safe(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value), do: value

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_title: Map.get(issue, :title),
      issue_state: Map.get(issue, :state),
      issue_url: Map.get(issue, :url)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_title: nil,
      issue_state: nil,
      issue_url: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_title: nil,
      issue_state: nil,
      issue_url: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
