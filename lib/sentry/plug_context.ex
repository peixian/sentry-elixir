defmodule Sentry.PlugContext do
  @moduledoc """
  This module adds Sentry context metadata during the request in a Plug
  application.

  It includes defaults for scrubbing sensitive data, and options for customizing it
  by default. It is intended for usage with `Sentry.PlugCapture` as metadata added
  here will appear in events captured.

  ## Scrubbing `POST` Body Params

  In order to send `POST` body parameters you should first scrub them of sensitive
  information. By default, they will be scrubbed with `default_body_scrubber/1`. This
  can be overridden by passing the `:body_scrubber` option, which accepts a `Plug.Conn`
  and returns a map to send.  Setting `:body_scrubber` to `nil` will not send any data
  back. If you would like to make use of Sentry's default scrubber behavior in a custom
  scrubber, it can be called directly. An example configuration may look like
  the following:

      defmodule MySentryScrubber do
        def scrub_params(conn) do
          # Makes use of the default body_scrubber to avoid sending password
          # and credit card information in plain text. To also prevent sending
          # our sensitive "my_secret_field" and "other_sensitive_data" fields,
          # we simply drop those keys.
          conn
          |> Sentry.PlugContext.default_body_scrubber()
          |> Map.drop(["my_secret_field", "other_sensitive_data"])
        end
      end

  Then pass it into `Sentry.PlugContext`:

      plug Sentry.PlugContext, body_scrubber: &MySentryScrubber.scrub_params/1

  You can also pass it in as a `{module, fun}`, like so:

      plug Sentry.PlugContext, body_scrubber: {MyModule, :scrub_params}

  > #### Large Files {: .tip}
  >
  > If you are sending large files in `POST` requests, we recommend you
  > scrub them out through the `:body_scrubber` mechanism.

  ### Scrubbing Headers

  By default, Sentry uses `default_header_scrubber/1` to scrub headers. This can be
  configured similarly to body params, through the `:header_scrubber` configuration
  option:

      defmodule MyHeaderScrubber do
        def scrub_headers(conn) do
          # In this example, we do not want to include Content-Type or User-Agent
          # in reported headers, so we drop them.
          conn.req_headers
          |> Map.new()
          |> Sentry.PlugContext.default_header_scrubber()
          |> Map.drop(["content-type", "user-agent"])
        end
      end

  Then, pass it into `Sentry.PlugContext`:

      plug Sentry.PlugContext, header_scrubber: &MyHeaderScrubber.scrub_headers/1

  It can also be passed in as a `{module, fun}` like so:

      plug Sentry.PlugContext, header_scrubber: {MyModule, :scrub_headers}

  ### Scrubbing Cookies

  By default Sentry will scrub all cookies before sending events
  (see `scrub_cookies/1`). It can be configured similarly to the headers
  and body scrubbers, but is configured via the `:cookie_scrubber` key.

  For example:

      plug Sentry.PlugContext, cookie_scrubber: &MyCookieScrubber.scrub_cookies/1

  ## Including Request Identifiers

  If you're using Phoenix, `Plug.RequestId`, or any other method to set a *request ID*
  response header, and would like to include that information with errors
  reported by `Sentry.PlugContext`, use the `:request_id_header` option. It allows you to set
  which header key Sentry should check. It defaults to `x-request-id`,
  which `Plug.RequestId` (and therefore Phoenix) also default to.

      plug Sentry.PlugContext, request_id_header: "application-request-id"

  ## Remote Address Reader

  `Sentry.PlugContext` includes a request's originating IP address under the `REMOTE_ADDR`
  environment key in Sentry. By default, we read it from the `x-forwarded-for` HTTP header,
  and if this header is not present, from `conn.remote_ip`.

  If you wish to read this value differently (for example, from a different HTTP header),
  or modify it in some other way (such as by masking it), you can configure this behavior
  by passing the `:remote_address_reader` option:

      plug Sentry.PlugContext, remote_address_reader: &MyModule.read_ip/1

  The `:remote_address_reader` option must be a function that accepts a `Plug.Conn`
  returns a `t:String.t/0` IP, or a `{module, function}` tuple, where `module.function/1`
  takes a `Plug.Conn` and returns a `t:String.t/0` IP.
  """

  if Code.ensure_loaded?(Plug) do
    @behaviour Plug

    @impl Plug
    def init(opts) do
      opts
    end

    @impl Plug
    def call(conn, opts) do
      request = build_request_interface_data(conn, opts)
      Sentry.Context.set_request_context(request)
      conn
    end
  end

  @default_scrubbed_param_keys ["password", "passwd", "secret"]
  @default_scrubbed_header_keys ["authorization", "authentication", "cookie"]
  @credit_card_regex ~r/^(?:\d[ -]*?){13,16}$/
  @scrubbed_value "*********"
  @default_plug_request_id_header "x-request-id"

  @doc false
  @spec build_request_interface_data(Plug.Conn.t(), keyword()) :: map()
  def build_request_interface_data(conn, opts) do
    body_scrubber = Keyword.get(opts, :body_scrubber, {__MODULE__, :default_body_scrubber})

    header_scrubber = Keyword.get(opts, :header_scrubber, {__MODULE__, :default_header_scrubber})

    cookie_scrubber = Keyword.get(opts, :cookie_scrubber, {__MODULE__, :default_cookie_scrubber})

    request_id = Keyword.get(opts, :request_id_header) || @default_plug_request_id_header

    remote_address_reader =
      Keyword.get(opts, :remote_address_reader, {__MODULE__, :default_remote_address_reader})

    conn =
      Plug.Conn.fetch_cookies(conn)
      |> Plug.Conn.fetch_query_params()

    %{
      url: Plug.Conn.request_url(conn),
      method: conn.method,
      data: handle_data(conn, body_scrubber),
      query_string: conn.query_string,
      cookies: handle_data(conn, cookie_scrubber),
      headers: handle_data(conn, header_scrubber),
      env: %{
        "REMOTE_ADDR" => handle_data(conn, remote_address_reader),
        "REMOTE_PORT" => remote_port(conn),
        "SERVER_NAME" => conn.host,
        "SERVER_PORT" => conn.port,
        "REQUEST_ID" => Plug.Conn.get_resp_header(conn, request_id) |> List.first()
      }
    }
  end

  @doc false
  @spec default_remote_address_reader(Plug.Conn.t()) :: String.t()
  def default_remote_address_reader(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [header_value | _rest] ->
        header_value
        |> String.split(",")
        |> hd()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> case do
          {:error, _} -> ""
          address -> to_string(address)
        end
    end
  end

  defp remote_port(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] -> nil
      [_value | _rest] -> Plug.Conn.get_peer_data(conn).port
    end
  end

  defp handle_data(_conn, nil), do: %{}

  defp handle_data(conn, {module, fun}) do
    apply(module, fun, [conn])
  end

  defp handle_data(conn, fun) when is_function(fun) do
    fun.(conn)
  end

  @doc """
  Scrubs **all** cookies off of the request.
  """
  @spec default_cookie_scrubber(Plug.Conn.t()) :: map()
  def default_cookie_scrubber(_conn) do
    %{}
  end

  @doc """
  Scrubs the headers of a request.

  The default scrubbed headers are:

  #{Enum.map_join(@default_scrubbed_header_keys, "\n", &"*  `#{&1}`")}
  """
  @spec default_header_scrubber(Plug.Conn.t()) :: map()
  def default_header_scrubber(conn) do
    conn.req_headers
    |> Map.new()
    |> Map.drop(@default_scrubbed_header_keys)
  end

  @doc """
  Scrubs the body of a request.

  The default scrubbed keys are:

  #{Enum.map_join(@default_scrubbed_param_keys, "\n", &"*  `#{&1}`")}
  """
  @spec default_body_scrubber(Plug.Conn.t()) :: map()
  def default_body_scrubber(conn) do
    scrub_map(conn.params, @default_scrubbed_param_keys)
  end

  defp scrub_map(map, scrubbed_keys) do
    Map.new(map, fn {key, value} ->
      value =
        cond do
          key in scrubbed_keys -> @scrubbed_value
          is_binary(value) and value =~ @credit_card_regex -> @scrubbed_value
          is_struct(value) -> value |> Map.from_struct() |> scrub_map(scrubbed_keys)
          is_map(value) -> scrub_map(value, scrubbed_keys)
          is_list(value) -> scrub_list(value, scrubbed_keys)
          true -> value
        end

      {key, value}
    end)
  end

  defp scrub_list(list, scrubbed_keys) do
    Enum.map(list, fn value ->
      cond do
        is_struct(value) -> value |> Map.from_struct() |> scrub_map(scrubbed_keys)
        is_map(value) -> scrub_map(value, scrubbed_keys)
        is_list(value) -> scrub_list(value, scrubbed_keys)
        true -> value
      end
    end)
  end
end
