defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!(issue)
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, workflow}, issue) do
    state_prompt(workflow[:config] || %{}, issue) || default_prompt(workflow[:prompt_template])
  end

  defp prompt_template!({:error, reason}, _issue) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp state_prompt(config, issue) when is_map(config) do
    prompts =
      config
      |> map_get("prompts")
      |> fallback_map_get(config, "prompt_templates")
      |> fallback_map_get(config, "state_prompts")

    with %{} <- prompts,
         state when is_binary(state) and state != "" <- normalize_state(issue_state(issue)),
         prompt when is_binary(prompt) <- find_state_prompt(prompts, state),
         true <- String.trim(prompt) != "" do
      prompt
    else
      _ -> nil
    end
  end

  defp state_prompt(_config, _issue), do: nil

  defp fallback_map_get(nil, config, key), do: map_get(config, key)
  defp fallback_map_get(value, _config, _key), do: value

  defp find_state_prompt(prompts, wanted_state) when is_map(prompts) do
    Enum.find_value(prompts, fn {state_name, raw_prompt} ->
      if normalize_state(to_string(state_name)) == wanted_state do
        prompt_value(raw_prompt)
      end
    end)
  end

  defp prompt_value(prompt) when is_binary(prompt), do: prompt
  defp prompt_value(%{} = prompt), do: map_get(prompt, "prompt") || map_get(prompt, "template")
  defp prompt_value(_prompt), do: nil

  defp issue_state(%{state: state}), do: state
  defp issue_state(%{"state" => state}), do: state
  defp issue_state(_issue), do: nil

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, " ")
  end

  defp normalize_state(_state), do: ""

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
