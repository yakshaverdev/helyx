defmodule Helyx.Tool.WebFetch do
  # The bounds of a call. Each has one holder, named in the doc and read by
  # a test (`docs/features/web-fetch.md`, "Bounds").
  @max_url_bytes 2_048
  @download_bytes 2 * 1_048_576
  @max_redirects 5
  @deadline_ms 30_000
  @max_type_bytes 200
  @max_error_bytes 2_000

  # The result text: the bound of a tool result of the other tools, so the
  # first line and the text fit `Helyx.Message.max_result_bytes/0` together.
  @max_bytes Helyx.Text.max_bytes()
  @cut_marker "\n[… cut …]"

  # The longest first line, the longest note of a cut body, and the marker.
  @head_bytes @max_url_bytes + @max_type_bytes + 32
  @note_bytes 96

  if @head_bytes + 1 + @note_bytes + @max_bytes + byte_size(@cut_marker) >
       Helyx.Message.max_result_bytes(),
     do: raise("the web_fetch result does not fit Helyx.Message.max_result_bytes/0")

  @accept "text/markdown, text/plain, text/html"
  @redirects [301, 302, 303, 307, 308]
  @utf8_error "the page is not valid UTF-8"
  @timeout_error "the fetch timed out after #{@deadline_ms} ms"
  @options_error "the web_fetch options are not a keyword list with a resolver of two arguments"

  @empty %{chunks: [], size: 0, cut?: false}

  @moduledoc """
  Fetches a URL and returns the page as text (`docs/features/web-fetch.md`).
  The arguments are `url`, an http or https URL, and `max_bytes`, the most
  bytes of text to return.

  The first line of the result is the final URL, the status, and the content
  type. HTML becomes text; another `text/*`, JSON, or XML type is returned
  as it is; another type is an error result that names it. The text is cut
  at `max_bytes` bytes on a character boundary with the marker `[… cut …]`.
  A status of 400 or more is an error result with the status and the first
  #{@max_error_bytes} bytes of the text.

  The addresses of the host are checked before the request: a loopback,
  link-local, private, shared, unique-local, multicast, reserved, or
  unspecified address is an error result, and so is a redirect to one. One call reads at most
  #{@download_bytes} bytes of a body, follows at most #{@max_redirects}
  redirects, and ends within #{@deadline_ms} ms with an error result.

  The application env key `:web_fetch_req_options` of `helyx_plugins` holds
  a keyword list for `Req`; its `:resolver` key is a function of the host
  and `:inet` or `:inet6` that replaces the host lookup.
  """

  @behaviour Helyx.Tool

  import Bitwise

  alias Helyx.Tool.Args
  alias Helyx.Tool.WebFetch.Text

  @doc "The byte bound of the `url` argument."
  @spec max_url_bytes() :: pos_integer()
  def max_url_bytes, do: @max_url_bytes

  @doc "The byte bound of a body that one call reads."
  @spec download_bytes() :: pos_integer()
  def download_bytes, do: @download_bytes

  @doc "The most redirects that one call follows."
  @spec max_redirects() :: non_neg_integer()
  def max_redirects, do: @max_redirects

  @doc "The time limit of one call, in ms, for the host lookup and every hop."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc "The byte bound of the content type in the result."
  @spec max_type_bytes() :: pos_integer()
  def max_type_bytes, do: @max_type_bytes

  @doc "The byte bound of the text of a status of 400 or more."
  @spec max_error_bytes() :: pos_integer()
  def max_error_bytes, do: @max_error_bytes

  @doc "The default and the most of the `max_bytes` argument."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @impl true
  def name, do: "web_fetch"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Fetch a URL and return the page as text: HTML becomes its text, and a " <>
      "text, JSON, or XML body is returned as it is. The first line names the " <>
      "final URL, the status, and the content type; the text is at most " <>
      "#{@max_bytes} bytes, and `max_bytes` lowers that. An address that is " <>
      "not public (loopback, private, link-local) is refused."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @max_url_bytes,
          "description" => "The http or https URL to fetch"
        },
        "max_bytes" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_bytes,
          "default" => @max_bytes,
          "description" => "The most bytes of text to return"
        }
      },
      "required" => ["url"],
      "additionalProperties" => false
    }
  end

  @impl true
  def run(args, _cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         {:ok, url} <- url(args["url"]),
         {:ok, options} <- options() do
      deadline = now() + @deadline_ms
      task = Task.async(fn -> hop(url, args["max_bytes"], options, @max_redirects, deadline) end)

      # The limits of a hop do not bound a connect, so the call has one hard
      # limit too: the kill closes the connection of the Task.
      case Task.yield(task, @deadline_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, @timeout_error}
      end
    end
  end

  # Config is a boundary: a keyword list, and a resolver of two arguments.
  defp options do
    options = Application.get_env(:helyx_plugins, :web_fetch_req_options, [])

    if is_list(options) and Keyword.keyword?(options) and
         is_function(Keyword.get(options, :resolver, &default_resolver/2), 2),
       do: {:ok, options},
       else: {:error, @options_error}
  end

  defp resolver(options), do: Keyword.get(options, :resolver, &default_resolver/2)

  # The resolver reaches `Req` as our own key only; every other key is its.
  defp req_options(options), do: Keyword.delete(options, :resolver)

  defp default_resolver(host, family), do: :inet.getaddrs(String.to_charlist(host), family)

  # A URL from the model or from a redirect: the same rules for both. The
  # arguments are checked against the schema at the entry, but a redirect
  # target never is, so the byte bound is checked here too.
  defp url(text) when byte_size(text) > @max_url_bytes,
    do: {:error, "url must be a string of 1 to #{@max_url_bytes} bytes"}

  defp url(text) do
    case URI.new(text) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        if uri.host in [nil, ""], do: {:error, "url has no host"}, else: {:ok, uri}

      {:ok, _uri} ->
        {:error, "url must be an http or https URL"}

      {:error, _part} ->
        {:error, "url is not a valid URL"}
    end
  end

  # One hop of the chain. The address of every host is checked before its
  # request, and a redirect target goes through the same check.
  defp hop(url, max_bytes, options, redirects, deadline) do
    with {:ok, url} <- public(url, resolver(options), deadline),
         {:ok, response, body} <- request(url, req_options(options), deadline) do
      follow_or_answer(url, response, body, max_bytes, options, redirects, deadline)
    end
  end

  defp follow_or_answer(url, response, body, max_bytes, options, redirects, deadline) do
    case location(response) do
      :none ->
        answer(url, response, body, max_bytes)

      {:error, text} ->
        {:error, text}

      {:ok, _location} when redirects == 0 ->
        {:error, "the page redirects more than #{@max_redirects} times"}

      {:ok, location} ->
        follow(url, location, max_bytes, options, redirects, deadline)
    end
  end

  defp follow(url, location, max_bytes, options, redirects, deadline) do
    with {:ok, next} <- url(URI.merge(url, location) |> URI.to_string()) do
      hop(next, max_bytes, options, redirects - 1, deadline)
    end
  end

  defp location(%{status: status} = response) when status in @redirects do
    case response.headers["location"] do
      [location | _] -> {:ok, location}
      _other -> {:error, "the #{status} response has no location"}
    end
  end

  defp location(_response), do: :none

  # The lookup and the request share the one deadline of the call: each gets
  # the time that is left.
  defp request(url, options, deadline) do
    with {:ok, left} <- left(deadline) do
      request =
        Req.new(
          [
            method: :get,
            url: URI.to_string(url),
            headers: [{"accept", @accept}, {"accept-encoding", "identity"}],
            into: &collect/2,
            redirect: false,
            retry: false,
            http_errors: :return,
            decode_body: false,
            finch: [pool_timeout: left],
            receive_timeout: left,
            request_timeout: left
          ] ++ options
        )

      case Req.request(request) do
        {:ok, response} -> {:ok, response, body(response)}
        {:error, exception} -> {:error, "the request failed: " <> Helyx.Reason.text(exception)}
      end
    end
  end

  defp left(deadline) do
    case deadline - now() do
      left when left > 0 -> {:ok, left}
      _past -> {:error, @timeout_error}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The body is read as a stream and stops at the download bound, so a larger
  # body never sits in memory. The state rides in the response, which is new
  # for each request.
  defp collect({:data, data}, {request, response}) do
    state = Map.get(response.private, :web_fetch_body, @empty)
    room = @download_bytes - state.size

    if byte_size(data) <= room do
      state = %{state | chunks: [data | state.chunks], size: state.size + byte_size(data)}
      {:cont, {request, put_in(response.private[:web_fetch_body], state)}}
    else
      kept = binary_part(data, 0, room)
      state = %{state | chunks: [kept | state.chunks], size: @download_bytes, cut?: true}
      {:halt, {request, put_in(response.private[:web_fetch_body], state)}}
    end
  end

  defp body(response) do
    state = Map.get(response.private, :web_fetch_body, @empty)
    {state.chunks |> Enum.reverse() |> IO.iodata_to_binary(), state.cut?}
  end

  # The content type decides whether the body is text at all, then the
  # charset, and the status last: a body that the tool cannot read as text is
  # an error whatever its status.
  defp answer(url, response, {bytes, cut?}, max_bytes) do
    status = response.status

    with {:ok, type, charset} <- content_type(response),
         {:ok, text} <- decode(type, bytes, charset, cut?) do
      head = "#{URI.to_string(url)} (#{status}, #{type})"

      if status >= 400 do
        {:error, head <> "\n" <> Helyx.Text.cap(text, @max_error_bytes, :head)}
      else
        {:ok, head <> "\n" <> cut(text, max_bytes) <> note(cut?)}
      end
    end
  end

  defp content_type(response) do
    case response.headers["content-type"] do
      [value | _] -> parse_type(value)
      _other -> {:error, "the response has no content type"}
    end
  end

  defp parse_type(value) do
    [essence | params] = String.split(value, ";")
    type = essence |> String.trim() |> String.downcase() |> Helyx.Text.cap(@max_type_bytes, :head)

    if type == "",
      do: {:error, "the response has no content type"},
      else: {:ok, type, charset(params)}
  end

  defp charset(params) do
    Enum.find_value(params, "utf-8", &charset_param/1)
  end

  defp charset_param(param) do
    case String.split(param, "=", parts: 2) do
      [name, value] -> if charset_name?(name), do: clean_charset(value)
      _other -> nil
    end
  end

  defp charset_name?(name), do: String.downcase(String.trim(name)) == "charset"

  defp clean_charset(value),
    do: value |> String.trim() |> String.trim("\"") |> String.downcase()

  defp decode(type, bytes, charset, cut?) do
    with :ok <- readable(type),
         {:ok, text} <- charset_text(bytes, charset, cut?) do
      if type == "text/html", do: {:ok, Text.to_text(text)}, else: {:ok, text}
    end
  end

  defp readable(type) do
    cond do
      String.starts_with?(type, "text/") -> :ok
      type in ["application/json", "application/xml"] -> :ok
      String.ends_with?(type, "+json") -> :ok
      String.ends_with?(type, "+xml") -> :ok
      true -> {:error, "the content type is #{type}, which the tool does not read"}
    end
  end

  defp charset_text(bytes, "utf-8", cut?), do: utf8(bytes, cut?)

  defp charset_text(bytes, charset, _cut?) when charset in ["latin1", "iso-8859-1"] do
    # Every latin1 byte is a character, so the conversion always gives text.
    text = :unicode.characters_to_binary(bytes, :latin1, :utf8)
    true = is_binary(text)
    {:ok, text}
  end

  defp charset_text(_bytes, charset, _cut?),
    do: {:error, "the charset #{charset} is not supported"}

  # The download bound can split a character: only a body that was cut drops
  # the incomplete character at its end. A body that is not valid UTF-8 on
  # its own is an error.
  defp utf8(bytes, true) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      text when is_binary(text) -> {:ok, text}
      {:incomplete, text, _rest} -> {:ok, text}
      {:error, _text, _rest} -> {:error, @utf8_error}
    end
  end

  defp utf8(bytes, false) do
    if String.valid?(bytes), do: {:ok, bytes}, else: {:error, @utf8_error}
  end

  defp cut(text, max) do
    if byte_size(text) <= max,
      do: text,
      else: Helyx.Text.cap(text, max, :head) <> @cut_marker
  end

  defp note(true), do: "\n[the body is over the #{@download_bytes}-byte download bound]"
  defp note(false), do: ""

  # The host is resolved once, in a Task with the time that is left, and
  # every address is checked. A name that answers with one private address
  # is refused: the request can take either answer.
  defp public(url, resolver, deadline) do
    with {:ok, addresses} <- resolve(url.host, resolver, deadline) do
      if Enum.all?(addresses, &public?/1),
        do: {:ok, url},
        else: {:error, "the address is not public"}
    end
  end

  defp resolve(host, resolver, deadline) do
    task = Task.async(fn -> lookup(host, resolver) end)
    wait = max(deadline - now(), 0)

    case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, [_ | _] = addresses}} -> {:ok, addresses}
      _past -> {:error, "the host did not resolve: #{host}"}
    end
  end

  # An address literal is its own answer; a name goes to both families.
  defp lookup(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, _reason} -> getaddrs(host, resolver)
    end
  end

  defp getaddrs(host, resolver) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, answers} <- [resolver.(host, family)],
          address <- answers,
          do: address

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp public?({0, _, _, _}), do: false
  defp public?({127, _, _, _}), do: false
  defp public?({10, _, _, _}), do: false
  defp public?({172, second, _, _}) when second in 16..31, do: false
  defp public?({192, 168, _, _}), do: false
  defp public?({169, 254, _, _}), do: false
  # The shared range of a carrier NAT, which an overlay network also uses.
  defp public?({100, second, _, _}) when second in 64..127, do: false
  defp public?({192, 0, 0, _}), do: false
  defp public?({198, second, _, _}) when second in 18..19, do: false
  # Multicast, reserved, and broadcast.
  defp public?({first, _, _, _}) when first >= 224, do: false
  defp public?({_, _, _, _}), do: true

  defp public?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: public?(ipv4(high, low))
  defp public?({0, 0, 0, 0, 0, 0, high, low}), do: public?(ipv4(high, low))
  # An IPv4 address in the NAT64 and the 6to4 form.
  defp public?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: public?(ipv4(high, low))
  defp public?({0x2002, high, low, _, _, _, _, _}), do: public?(ipv4(high, low))
  defp public?({first, _, _, _, _, _, _, _}) when first >= 0xFF00, do: false
  defp public?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: false
  defp public?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: false
  defp public?({_, _, _, _, _, _, _, _}), do: true

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}
end
