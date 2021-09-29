defmodule Bureaucrat.ApiBlueprintWriter do
  alias Bureaucrat.JSON

  def write(records, path) do
    file = File.open!(path, [:write, :utf8])
    records = group_records(records)
    title = Application.get_env(:bureaucrat, :title)
    puts(file, "# #{title}\n\n")
    write_intro(path, file)
    write_api_doc(records, file)
  end

  defp write_intro(path, file) do
    intro_file_path =
      [
        # /path/to/API.md -> /path/to/API_INTRO.md
        String.replace(path, ~r/\.md$/i, "_INTRO\\0"),
        # /path/to/api.md -> /path/to/api_intro.md
        String.replace(path, ~r/\.md$/i, "_intro\\0"),
        # /path/to/API -> /path/to/API_INTRO
        "#{path}_INTRO",
        # /path/to/api -> /path/to/api_intro
        "#{path}_intro"
      ]
      # which one exists?
      |> Enum.find(nil, &File.exists?/1)

    if intro_file_path do
      file
      |> puts(File.read!(intro_file_path))
      |> puts("\n\n## Endpoints\n\n")
    else
      puts(file, "# API Documentation\n")
    end
  end

  defp write_api_doc(group_records, file) do
    Enum.each(group_records, fn {group, records} ->
      group =
        if group == "" do
          "API"
        else
          group
        end

      puts(file, "\n# Group #{group}")

      Enum.each(records, fn {controller, actions} ->
        path = get_path_from_actions(actions)

        if path do
          puts(file, "## #{controller} [#{path}]")
        end

        Enum.each(actions, fn {action, records} ->
          # do not sort channel by status code
          if group == "Channel" do
            records
            |> Enum.each(&write_action(&1, action, file))
          else
            records
            |> sort_by_status_code
            |> Enum.each(&write_action(&1, action, file))
          end
        end)
      end)
    end)

    puts(file, "")
  end

  defp get_path_from_actions(actions) do
    action = Enum.at(actions, 0) |> elem(1) |> List.first()
    get_path(action)
  end

  defp write_action(record, action, file) when is_map(record) do
    test_description = action
    method = record.method

    file
    |> puts("### #{test_description} [#{method} #{anchor(record)}]")
    |> puts("\n\n #{Keyword.get(record.assigns.bureaucrat_opts, :detail, "")}")

    write_parameters(record.path_params, file)

    write_example(record, file)
  end

  defp write_action(record, _action, file), do: write_example(record, file)

  defp write_example({%Phoenix.Socket.Broadcast{topic: topic, payload: payload, event: event}, _}, file) do
    file
    |> puts("#### Broadcast")
    |> puts("* __Topic:__ #{topic}")
    |> puts("* __Event:__ #{event}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({%Phoenix.Socket.Message{topic: topic, payload: payload, event: event}, _}, file) do
    file
    |> puts("#### Message")
    |> puts("* __Topic:__ #{topic}")
    |> puts("* __Event:__ #{event}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({%Phoenix.Socket.Reply{payload: payload, status: status}, _}, file) do
    file
    |> puts("#### Reply")
    |> puts("* __Status:__ #{status}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({{status, payload, %Phoenix.Socket{} = socket}, _}, file) do
    file
    |> puts("#### Join")
    |> puts("* __Topic:__ #{socket.topic}")
    |> puts("* __Receive:__ #{status}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_parameters(path_params, _file) when map_size(path_params) == 0, do: nil

  defp write_parameters(path_params, file) do
    file |> puts("\n+ Parameters\n#{formatted_params(path_params)}")

    Enum.each(path_params, fn {param, value} ->
      puts(file, indent_lines(12, "#{param}: #{value}"))
    end)

    file
  end

  defp sort_by_status_code(records) do
    records |> Enum.sort_by(& &1.status)
  end

  defp write_example(record, file) do
    write_request(record, file)
    write_response(record, file)
  end

  defp write_request(record, file) do
    path = get_request_path(record)

    file
    |> puts("\n\n+ Request #{record.assigns.bureaucrat_desc}")
    |> puts("**#{record.method}**&nbsp;&nbsp;`#{path}`\n")

    write_headers(record.req_headers, file)
    write_request_body(record.body_params, file)
  end

  defp get_request_path(record) do
    case record.query_string do
      "" -> record.request_path
      str -> "#{record.request_path}?#{str}"
    end
  end

  defp write_headers(_headers = [], _file), do: nil

  defp write_headers(headers, file) do
    file |> puts(indent_lines(4, "+ Headers\n"))

    Enum.each(headers, fn {header, value} ->
      puts(file, indent_lines(12, "#{header}: #{value}"))
    end)

    file
  end

  defp write_request_body(params, file) do
    case params == %{} do
      true ->
        nil

      false ->
        file
        |> puts(indent_lines(4, "+ Body\n"))
        |> puts(indent_lines(12, format_request_body(params)))
    end
  end

  defp write_response(record, file) do
    file |> puts("\n+ Response #{record.status}\n")
    write_headers(record.resp_headers, file)
    write_response_body(record.resp_body, file)
  end

  defp write_response_body(params, _file) when map_size(params) == 0, do: nil

  defp write_response_body(params, file) do
    file
    |> puts(indent_lines(4, "+ Body\n"))
    |> puts(indent_lines(12, format_response_body(params)))
  end

  def format_request_body(params) do
    {:ok, json} = JSON.encode(params, pretty: true)
    json
  end

  defp format_response_body("") do
    ""
  end

  defp format_response_body(string) do
    {:ok, struct} = JSON.decode(string)
    {:ok, json} = JSON.encode(struct, pretty: true)
    json
  end

  def indent_lines(number_of_spaces, string) do
    String.split(string, "\n")
    |> Enum.map(fn a -> String.pad_leading("", number_of_spaces) <> a end)
    |> Enum.join("\n")
  end

  def formatted_params(uri_params) do
    Enum.map(uri_params, &format_param/1) |> Enum.join("\n")
  end

  def format_param(param) do
    "    + #{URI.encode(elem(param, 0))}: `#{URI.encode(elem(param, 1))}`"
  end

  def anchor(record) do
    if map_size(record.path_params) == 0 do
      record.request_path
    else
      Enum.join([""] ++ set_params(record), "/")
    end
  end

  defp set_params(record) do
    Enum.flat_map(record.path_info, fn part ->
      case Enum.find(record.path_params, fn {_key, val} -> val == part end) do
        {param, _} -> ["{#{param}}"]
        nil -> [part]
      end
    end)
  end

  defp puts(file, string) do
    IO.puts(file, string)
    file
  end

  def controller_name(module) do
    prefix = Application.get_env(:bureaucrat, :prefix)

    Regex.run(~r/#{prefix}(.+)/, module, capture: :all_but_first)
    |> List.first()
    |> String.trim("Controller")
    |> Inflex.pluralize()
  end

  defp group_records(records) do
    by_group = Enum.group_by(records, &get_group/1)

    Enum.map(by_group, fn {g, g_recs} ->
      by_controller = Enum.group_by(g_recs, &get_controller_without_group/1)

      c_recs_group =
        Enum.map(by_controller, fn {c, c_recs} ->
          {c, Enum.group_by(c_recs, &get_action/1)}
        end)

      {g, c_recs_group}
    end)
  end

  defp strip_ns(module) do
    case to_string(module) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp get_group({_, _opts}), do: "Channel"
  defp get_group(conn), do: parse_group_title(get_controller(conn))

  defp parse_group_title(nil), do: {nil, nil}

  defp parse_group_title(controller) do
    [_ | namespaces] = String.split(controller, ".") |> Enum.reverse()

    namespaces
    |> Enum.reverse()
    |> Enum.drop(1)
    |> Enum.join(" ")
  end

  defp parse_controller_title(nil), do: {nil, nil}

  defp parse_controller_title(controller) do
    controller_title = String.split(controller, ".") |> List.last()

    String.replace_suffix(controller_title, "Controller", "")
  end

  defp get_controller_without_group(args), do: parse_controller_title(get_controller(args))

  defp get_controller({_, opts}),
    do: opts[:group_title] || String.replace_suffix(strip_ns(opts[:module]), "Test", "")

  defp get_controller(conn),
    do: conn.assigns.bureaucrat_opts[:group_title] || strip_ns(conn.private.phoenix_controller)

  defp get_action({_, opts}), do: opts[:description]
  defp get_action(conn), do: conn.private.phoenix_action

  defp get_path({%Phoenix.Socket.Broadcast{event: event}, _}), do: event
  defp get_path({%Phoenix.Socket.Message{event: event}, _}), do: event
  defp get_path({%Phoenix.Socket.Reply{payload: payload, topic: topic}, _}), do: topic
  defp get_path({{status, payload, %Phoenix.Socket{} = socket}, _}), do: status
  defp get_path(conn), do: conn.request_path

  def format_body_params(params) do
    {:ok, json} = JSON.encode(params, pretty: true)
    json
  end
end
