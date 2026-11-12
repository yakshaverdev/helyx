defmodule Helyx.Tool.WebFetchTest do
  # The tool at its boundary: the arguments, the address rules, the redirect
  # chain, the bounds, the charset, and the result
  # (`Helyx.Tool.WebFetch`, `docs/features/web-fetch.md`). The `Req` adapter
  # is the stub of the application env, so no test opens a socket.
  # Not async: the tests set the :web_fetch_req_options app env.
  use ExUnit.Case, async: false

  alias Helyx.Tool.WebFetch

  # The `Req` adapter that a refused connection answers with, for the
  # transport-error test: a module, since a function is deprecated.
  defmodule Refused do
    @moduledoc false
    def run(request), do: {request, %Req.TransportError{reason: :econnrefused}}
  end

  # The `Req` adapter that records the time limits of its request and answers
  # a page, for the test of the deadline. A test that waited the deadline out
  # would hold the suite for its whole length, so the test reads the limits
  # that the hop gives `Req` instead.
  defmodule Spy do
    @moduledoc false
    def run(request) do
      option = fn key -> Req.Request.get_option(request, key) end

      :ets.insert(
        :web_fetch_spy,
        {:limits, option.(:connect_options), option.(:receive_timeout), option.(:request_timeout)}
      )

      response =
        Req.Response.new(status: 200) |> Req.Response.put_header("content-type", "text/plain")

      {request, response}
    end
  end

  # A public address, the one that the checks of these tests accept.
  @public [{93, 184, 216, 34}]

  setup do
    Application.put_env(:helyx_plugins, :web_fetch_req_options, [])
    on_exit(fn -> Application.delete_env(:helyx_plugins, :web_fetch_req_options) end)
  end

  defp run(args), do: WebFetch.run(args, System.tmp_dir!())

  defp url(path \\ "/"), do: "http://docs.example" <> path

  defp resolver(ipv4, ipv6 \\ []) do
    fn
      _host, :inet -> {:ok, ipv4}
      _host, :inet6 -> {:ok, ipv6}
    end
  end

  defp public_resolver, do: resolver(@public)

  # The stub of the request: the address rules still run, so every stub
  # carries the resolver that answers them.
  defp stub(status, type, body, resolver \\ nil) do
    plug = fn conn ->
      conn = if type, do: Plug.Conn.put_resp_header(conn, "content-type", type), else: conn
      Plug.Conn.send_resp(conn, status, body)
    end

    Application.put_env(:helyx_plugins, :web_fetch_req_options,
      plug: plug,
      resolver: resolver || public_resolver()
    )
  end

  defp only_resolver(resolver) do
    Application.put_env(:helyx_plugins, :web_fetch_req_options, resolver: resolver)
  end

  defp counter, do: :counters.new(1, [])

  defp bump(counter) do
    :counters.add(counter, 1, 1)
    :counters.get(counter, 1)
  end

  test "a missing url, and a url that is not a string, are error results" do
    stub(200, "text/plain", "x")

    assert run(%{}) == {:error, "url is required"}
    assert run(%{"url" => nil}) == {:error, "url is required"}
    assert run(%{"url" => 1}) == {:error, "url must be a string"}
  end

  test "the url bound counts bytes: the bound is fetched, one byte over is an error" do
    stub(200, "text/plain", "ok")
    prefix = "http://docs.example/"

    at = prefix <> String.duplicate("a", WebFetch.max_url_bytes() - byte_size(prefix))
    assert byte_size(at) == WebFetch.max_url_bytes()
    assert {:ok, text} = run(%{"url" => at})
    assert String.starts_with?(text, at)

    under = binary_part(at, 0, byte_size(at) - 1)
    assert {:ok, _text} = run(%{"url" => under})

    assert run(%{"url" => at <> "a"}) ==
             {:error, "url must be a string of 1 to #{WebFetch.max_url_bytes()} bytes"}
  end

  test "the url bound counts bytes, so a multibyte url of fewer characters is over it" do
    stub(200, "text/plain", "ok")

    # 1,020 characters of two bytes each: over the byte bound, under the
    # character count.
    long = "http://docs.example/" <> String.duplicate("é", 1_020)
    assert byte_size(long) > WebFetch.max_url_bytes()
    assert String.length(long) < WebFetch.max_url_bytes()

    assert run(%{"url" => long}) ==
             {:error, "url must be a string of 1 to #{WebFetch.max_url_bytes()} bytes"}
  end

  test "max_bytes is an integer from 1 to the bound, and the default is the bound" do
    stub(200, "text/plain", "abcdef")
    head = "http://docs.example/ (200, text/plain)\n"

    assert run(%{"url" => url(), "max_bytes" => 3}) == {:ok, head <> "abc\n[… cut …]"}
    assert run(%{"url" => url(), "max_bytes" => WebFetch.max_bytes()}) == {:ok, head <> "abcdef"}
    assert run(%{"url" => url()}) == {:ok, head <> "abcdef"}

    for bad <- [0, -1, WebFetch.max_bytes() + 1] do
      assert run(%{"url" => url(), "max_bytes" => bad}) ==
               {:error, "max_bytes must be an integer from 1 to #{WebFetch.max_bytes()}"},
             inspect(bad)
    end

    for bad <- [1.0, "3", true] do
      assert run(%{"url" => url(), "max_bytes" => bad}) ==
               {:error, "max_bytes must be an integer"},
             inspect(bad)
    end
  end

  test "a text over the default is cut at the bound with the marker" do
    body = String.duplicate("a", WebFetch.max_bytes() + 10)
    stub(200, "text/plain", body)

    assert {:ok, text} = run(%{"url" => url()})
    assert String.ends_with?(text, "\n[… cut …]")

    assert byte_size(text) ==
             byte_size("http://docs.example/ (200, text/plain)\n") + WebFetch.max_bytes() +
               byte_size("\n[… cut …]")
  end

  test "the cut of max_bytes keeps a character that it does not split" do
    stub(200, "text/plain", "aéé")
    head = "http://docs.example/ (200, text/plain)\n"

    # Four bytes of "aéé" split the second "é", so it is dropped.
    assert run(%{"url" => url(), "max_bytes" => 4}) == {:ok, head <> "aé\n[… cut …]"}
    assert run(%{"url" => url(), "max_bytes" => 5}) == {:ok, head <> "aéé"}
  end

  test "an argument that the schema does not name is an error result" do
    stub(200, "text/plain", "ok")
    assert run(%{"url" => url(), "bytes" => 3}) == {:error, "bytes is not an argument"}
  end

  test "a url that is not http or https, and one that does not parse, are error results" do
    stub(200, "text/plain", "ok")

    for bad <- [
          "ftp://docs.example/x",
          "file:///etc/passwd",
          "javascript:alert(1)",
          "//docs.example/x"
        ] do
      assert run(%{"url" => bad}) == {:error, "url must be an http or https URL"}, bad
    end

    for bad <- ["not a url", "http://exa mple.com/"] do
      assert run(%{"url" => bad}) == {:error, "url is not a valid URL"}, bad
    end

    assert run(%{"url" => "http://"}) == {:error, "url has no host"}
  end

  test "a loopback, private, link-local, unique-local, or unspecified address is refused" do
    cases = [
      {[{127, 0, 0, 1}], []},
      {[{10, 1, 2, 3}], []},
      {[{172, 16, 0, 1}], []},
      {[{172, 31, 255, 255}], []},
      {[{192, 168, 1, 1}], []},
      {[{169, 254, 169, 254}], []},
      {[{0, 0, 0, 0}], []},
      {[{100, 64, 0, 1}], []},
      {[{100, 127, 255, 255}], []},
      {[{192, 0, 0, 1}], []},
      {[{198, 18, 0, 1}], []},
      {[{224, 0, 0, 1}], []},
      {[{255, 255, 255, 255}], []},
      # 127.0.0.1 in the NAT64 and the 6to4 form, and multicast
      {[], [{0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001}]},
      {[], [{0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 1}]},
      {[], [{0xFF02, 0, 0, 0, 0, 0, 0, 1}]},
      {[], [{0, 0, 0, 0, 0, 0, 0, 1}]},
      {[], [{0, 0, 0, 0, 0, 0, 0, 0}]},
      {[], [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]},
      {[], [{0xFE80, 0, 0, 0, 0, 0xFFFF, 0xFE00, 0x0001}]},
      {[], [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]},
      {[], [{0xFDFF, 0, 0, 0, 0, 0, 0, 1}]},
      # 127.0.0.1 and 10.0.0.1 in the IPv4-mapped form
      {[], [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}]},
      {[], [{0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}]},
      # one private address among the answers is enough
      {[{93, 184, 216, 34}], [{0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0001}]}
    ]

    for {ipv4, ipv6} <- cases do
      only_resolver(resolver(ipv4, ipv6))

      assert run(%{"url" => url()}) == {:error, "the address is not public"},
             inspect({ipv4, ipv6})
    end
  end

  test "a public address in either family is fetched" do
    stub(200, "text/plain", "ok")
    assert {:ok, _text} = run(%{"url" => url()})

    stub(
      200,
      "text/plain",
      "ok",
      resolver([], [{0x2606, 0x2800, 0x0220, 1, 0x0248, 0x1893, 0x25C8, 0x1946}])
    )

    assert {:ok, _text} = run(%{"url" => url()})
  end

  test "a url whose host is a refused address literal is refused, whatever the resolver says" do
    only_resolver(public_resolver())

    for host <- ["127.0.0.1", "[::1]", "169.254.169.254", "10.0.0.1", "0.0.0.0", "[fe80::1]"] do
      assert run(%{"url" => "http://" <> host <> "/"}) == {:error, "the address is not public"},
             host
    end
  end

  test "a host that does not resolve is an error result" do
    only_resolver(fn _host, _family -> {:error, :nxdomain} end)

    assert run(%{"url" => url()}) == {:error, "the host did not resolve: docs.example"}
  end

  test "a redirect is followed to its page, and the first line names the final url" do
    plug = fn conn ->
      case conn.request_path do
        "/old" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/new")
          |> Plug.Conn.send_resp(302, "")

        "/new" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/plain")
          |> Plug.Conn.send_resp(200, "here")
      end
    end

    Application.put_env(:helyx_plugins, :web_fetch_req_options,
      plug: plug,
      resolver: public_resolver()
    )

    assert run(%{"url" => url("/old")}) ==
             {:ok, "http://docs.example/new (200, text/plain)\nhere"}
  end

  test "a redirect to a private address, and one to another scheme, are refused" do
    resolver = fn
      "docs.example", :inet -> {:ok, @public}
      "internal.example", :inet -> {:ok, [{10, 1, 2, 3}]}
      _host, _family -> {:ok, []}
    end

    for {location, error} <- [
          {"http://internal.example/secret", "the address is not public"},
          {"file:///etc/passwd", "url must be an http or https URL"}
        ] do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")
      end

      Application.put_env(:helyx_plugins, :web_fetch_req_options,
        plug: plug,
        resolver: resolver
      )

      assert run(%{"url" => url()}) == {:error, error}, location
    end
  end

  test "at most the bound of redirects is followed" do
    counter = counter()

    plug = fn conn ->
      bump(counter)

      conn
      |> Plug.Conn.put_resp_header("location", "/again")
      |> Plug.Conn.send_resp(302, "")
    end

    Application.put_env(:helyx_plugins, :web_fetch_req_options,
      plug: plug,
      resolver: public_resolver()
    )

    assert {:error, text} = run(%{"url" => url()})
    assert text =~ "redirects more than #{WebFetch.max_redirects()} times"
    assert :counters.get(counter, 1) == WebFetch.max_redirects() + 1
  end

  test "the bound of redirects that ends in a page is followed" do
    counter = counter()

    plug = fn conn ->
      if bump(counter) <= WebFetch.max_redirects() do
        conn
        |> Plug.Conn.put_resp_header("location", "/again")
        |> Plug.Conn.send_resp(302, "")
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(200, "end")
      end
    end

    Application.put_env(:helyx_plugins, :web_fetch_req_options,
      plug: plug,
      resolver: public_resolver()
    )

    assert {:ok, text} = run(%{"url" => url()})
    assert String.ends_with?(text, "(200, text/plain)\nend")
  end

  test "a redirect with no location is an error result" do
    stub(301, "text/plain", "")
    assert run(%{"url" => url()}) == {:error, "the 301 response has no location"}
  end

  test "a body of the download bound is read whole, and one byte more is cut at the bound" do
    stub(200, "text/plain", String.duplicate("a", WebFetch.download_bytes()))

    assert {:ok, at_bound} = run(%{"url" => url()})
    refute at_bound =~ "download bound"
    assert String.ends_with?(at_bound, "a\n[… cut …]")

    stub(200, "text/plain", String.duplicate("a", WebFetch.download_bytes() + 1))
    assert {:ok, over} = run(%{"url" => url()})
    assert over =~ "[the body is over the #{WebFetch.download_bytes()}-byte download bound]"
  end

  test "html becomes text, and a text, json, or xml body is returned as it is" do
    stub(200, "text/html; charset=utf-8", "<h1>Title</h1><p>Body</p>")

    assert run(%{"url" => url()}) ==
             {:ok, "http://docs.example/ (200, text/html)\nTitle\n\nBody"}

    for {type, body} <- [
          {"text/plain", "plain"},
          {"text/markdown", "# md"},
          {"application/json", "{\"a\":1}"},
          {"application/xml", "<x/>"},
          {"application/ld+json", "{}"},
          {"image/svg+xml", "<svg/>"}
        ] do
      stub(200, type, body)
      assert {:ok, text} = run(%{"url" => url()})
      assert String.ends_with?(text, "\n" <> body), type
    end
  end

  test "another content type is an error result that names it" do
    stub(200, "application/octet-stream", <<0, 1, 2>>)

    assert run(%{"url" => url()}) ==
             {:error,
              "the content type is application/octet-stream, which the tool does not read"}

    stub(200, "image/png", "png")

    assert run(%{"url" => url()}) ==
             {:error, "the content type is image/png, which the tool does not read"}
  end

  test "a response with no content type is an error result" do
    stub(200, nil, "x")
    assert run(%{"url" => url()}) == {:error, "the response has no content type"}
  end

  test "the charset decides the decode: utf-8, latin1, and iso-8859-1" do
    stub(200, "text/plain; charset=utf-8", "héllo")
    assert {:ok, text} = run(%{"url" => url()})
    assert String.ends_with?(text, "\nhéllo")

    stub(200, "text/plain; charset=ISO-8859-1", "h" <> <<0xE9>> <> "llo")
    assert {:ok, text} = run(%{"url" => url()})
    assert String.ends_with?(text, "\nhéllo")

    stub(200, "text/plain; charset=latin1", <<0xE9>>)
    assert {:ok, text} = run(%{"url" => url()})
    assert String.ends_with?(text, "\né")
  end

  test "another charset, and a body that is not valid utf-8, are error results" do
    stub(200, "text/plain; charset=windows-1252", "x")
    assert run(%{"url" => url()}) == {:error, "the charset windows-1252 is not supported"}

    stub(200, "text/plain; charset=utf-8", <<0xFF, 0xFE>>)
    assert run(%{"url" => url()}) == {:error, "the page is not valid UTF-8"}
  end

  test "a character that the download bound splits is dropped, not an error" do
    body = String.duplicate("é", div(WebFetch.download_bytes(), 2)) <> "é"
    stub(200, "text/plain", body)

    assert {:ok, text} = run(%{"url" => url()})
    assert text =~ "download bound"
  end

  test "a status of 400 or more is an error result with the status and the text" do
    stub(404, "text/html", "<h1>Not found</h1><p>no page</p>")

    assert run(%{"url" => url()}) ==
             {:error, "http://docs.example/ (404, text/html)\nNot found\n\nno page"}
  end

  test "the text of an error status is cut at the error bound" do
    body = String.duplicate("x", WebFetch.max_error_bytes() + 100)
    stub(500, "text/plain", body)

    assert {:error, text} = run(%{"url" => url()})

    assert byte_size(text) ==
             byte_size("http://docs.example/ (500, text/plain)\n") + WebFetch.max_error_bytes()
  end

  test "the deadline is the time limit of the request" do
    _table = :ets.new(:web_fetch_spy, [:named_table, :public])

    Application.put_env(:helyx_plugins, :web_fetch_req_options,
      adapter: Spy,
      resolver: public_resolver()
    )

    assert {:ok, text} = run(%{"url" => url()})
    assert text == "http://docs.example/ (200, text/plain)\n"

    assert [{:limits, connect, receive, request}] = :ets.lookup(:web_fetch_spy, :limits)
    # A connect option would start one pool for each value: the pool is the
    # default one, and the kill of the call bounds the connect.
    assert connect == nil
    assert receive in 1..WebFetch.deadline_ms()
    assert request in 1..WebFetch.deadline_ms()
  end

  test "a transport error is an error result with its reason" do
    Application.put_env(:helyx_plugins, :web_fetch_req_options,
      adapter: Refused,
      resolver: public_resolver()
    )

    assert run(%{"url" => url()}) == {:error, "the request failed: connection refused"}
  end

  test "a web_fetch options value that is not a keyword list with a resolver is an error result" do
    for bad <- [%{}, [:a], [resolver: :nope], "nope"] do
      Application.put_env(:helyx_plugins, :web_fetch_req_options, bad)
      assert {:error, text} = run(%{"url" => url()})
      assert text =~ "web_fetch options", inspect(bad)
    end
  end
end
