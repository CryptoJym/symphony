defmodule SymphonyElixir.GitHubGate do
  @moduledoc """
  Optional GitHub issue allow-label gate for Linear-dispatched work.

  When configured, a Linear issue is dispatchable only when it links to exactly
  one GitHub issue in the configured repository and that GitHub issue is open,
  has every required label, and has none of the blocked labels.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @type gate_result :: {:ok, map()} | {:error, term()}

  @spec enabled?() :: boolean()
  def enabled?, do: enabled?(Config.settings!().tracker)

  @spec enabled?(map()) :: boolean()
  def enabled?(tracker) when is_map(tracker) do
    normalized_repo(tracker) != nil and normalized_labels(tracker, :required_github_labels) != []
  end

  def enabled?(_tracker), do: false

  @spec allowed?(Issue.t()) :: boolean()
  def allowed?(%Issue{} = issue) do
    case issue_allowed?(issue) do
      {:ok, _issue_data} ->
        true

      {:error, reason} ->
        Logger.info("Skipping #{issue.identifier || issue.id}: GitHub gate failed #{inspect(reason)}")

        false
    end
  end

  def allowed?(_issue), do: false

  @spec issue_allowed?(Issue.t()) :: gate_result()
  def issue_allowed?(%Issue{} = issue) do
    issue_allowed?(issue, Config.settings!().tracker, &view_issue/2)
  end

  @doc false
  @spec issue_allowed_for_test(Issue.t(), map(), (String.t(), pos_integer() -> gate_result())) ::
          gate_result()
  def issue_allowed_for_test(%Issue{} = issue, tracker, view_fun)
      when is_map(tracker) and is_function(view_fun, 2) do
    issue_allowed?(issue, tracker, view_fun)
  end

  defp issue_allowed?(%Issue{} = issue, tracker, view_fun) do
    if enabled?(tracker) do
      repo = normalized_repo(tracker)

      with {:ok, issue_number} <- source_issue_number(issue, repo, require_github_attachment?(tracker)),
           {:ok, github_issue} <- view_fun.(repo, issue_number),
           :ok <- github_issue_open?(github_issue),
           :ok <- required_labels_present?(github_issue, normalized_labels(tracker, :required_github_labels)),
           :ok <- blocked_labels_absent?(github_issue, normalized_labels(tracker, :blocked_github_labels)) do
        {:ok, github_issue}
      end
    else
      {:ok, %{gate: :disabled}}
    end
  end

  defp normalized_repo(tracker) when is_map(tracker) do
    tracker
    |> Map.get(:github_repo)
    |> normalize_string()
  end

  defp normalized_labels(tracker, field) when is_map(tracker) do
    tracker
    |> Map.get(field, [])
    |> List.wrap()
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(fn
      "" -> nil
      normalized -> normalized
    end)
  end

  defp normalize_label(_value), do: nil

  defp require_github_attachment?(tracker) when is_map(tracker) do
    Map.get(tracker, :require_github_attachment) == true
  end

  defp source_issue_number(issue, repo, require_attachment?) do
    attachment_numbers = extract_attachment_numbers(issue, repo)

    numbers =
      case {attachment_numbers, require_attachment?} do
        {[], true} -> []
        {[], false} -> extract_text_numbers(issue, repo)
        {numbers, _require_attachment?} -> numbers
      end
      |> Enum.uniq()

    case numbers do
      [number] -> {:ok, number}
      [] when require_attachment? -> {:error, :missing_github_issue_attachment}
      [] -> {:error, :missing_github_issue_link}
      numbers -> {:error, {:multiple_github_issue_links, numbers}}
    end
  end

  defp extract_attachment_numbers(%Issue{attachments: attachments}, repo) when is_list(attachments) do
    attachments
    |> Enum.flat_map(fn
      %{url: url} -> extract_repo_url_numbers(url, repo)
      %{"url" => url} -> extract_repo_url_numbers(url, repo)
      _ -> []
    end)
  end

  defp extract_attachment_numbers(_issue, _repo), do: []

  defp extract_text_numbers(%Issue{} = issue, repo) do
    [issue.title, issue.description]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn text ->
      extract_repo_url_numbers(text, repo) ++ extract_hash_numbers(text)
    end)
  end

  defp extract_repo_url_numbers(text, repo) when is_binary(text) and is_binary(repo) do
    escaped_repo = Regex.escape(repo)
    regex = ~r"https://github\.com/#{escaped_repo}/issues/(\d+)"i

    regex
    |> Regex.scan(text)
    |> Enum.map(fn [_match, number] -> String.to_integer(number) end)
  end

  defp extract_hash_numbers(text) when is_binary(text) do
    ~r/(?:^|[\s([{])#(\d{1,6})(?:\b|[)\]}.,;:])/u
    |> Regex.scan(text)
    |> Enum.map(fn [_match, number] -> String.to_integer(number) end)
  end

  defp github_issue_open?(%{"state" => state}) when is_binary(state) do
    if String.downcase(state) == "open", do: :ok, else: {:error, {:github_issue_not_open, state}}
  end

  defp github_issue_open?(_issue), do: {:error, :github_issue_missing_state}

  @spec required_labels_present?(map(), [String.t()]) :: :ok | {:error, {:missing_required_github_labels, [String.t()]}}
  defp required_labels_present?(github_issue, required_labels) do
    labels = github_issue_labels(github_issue)
    missing = Enum.reject(required_labels, &(&1 in labels))

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_required_github_labels, missing}}
    end
  end

  @spec blocked_labels_absent?(map(), [String.t()]) :: :ok | {:error, {:blocked_github_labels_present, [String.t()]}}
  defp blocked_labels_absent?(github_issue, blocked_labels) do
    labels = github_issue_labels(github_issue)
    present = Enum.filter(blocked_labels, &(&1 in labels))

    case present do
      [] -> :ok
      present -> {:error, {:blocked_github_labels_present, present}}
    end
  end

  @spec github_issue_labels(map()) :: [String.t()]
  defp github_issue_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} -> normalize_label(name)
      %{name: name} -> normalize_label(name)
      name when is_binary(name) -> normalize_label(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp github_issue_labels(_issue), do: []

  defp view_issue(repo, issue_number) when is_binary(repo) and is_integer(issue_number) do
    {output, status} =
      System.cmd(
        "gh",
        [
          "issue",
          "view",
          Integer.to_string(issue_number),
          "--repo",
          repo,
          "--json",
          "number,state,labels,title,url"
        ],
        stderr_to_stdout: true
      )

    case status do
      0 -> Jason.decode(output)
      _ -> {:error, {:gh_issue_view_failed, String.trim(output)}}
    end
  rescue
    error -> {:error, {:gh_issue_view_failed, Exception.message(error)}}
  end
end
