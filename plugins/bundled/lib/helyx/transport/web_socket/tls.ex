defmodule Helyx.Transport.WebSocket.TLS do
  @moduledoc """
  The key, the certificate, and the pin of the public listener of the wire
  (`docs/features/remote-hands.md`, "Pairing and the public listener").

  `ensure/1` makes an ECDSA P-256 key and a self-signed certificate on the
  first start with `--public`, under `<data folder>/tls/`, and reads them on
  every later start. The folder has mode 0700 and the key file 0600, before
  the first byte of the key is written. A file that exists and cannot be
  read as its part stops the start with `{:error, {:tls_file, path, reason}}`;
  only a missing pair makes a new one, so a damaged key never changes the
  pin without a message.

  The pin is the base64url, without padding, of the SHA-256 of the DER of the
  SubjectPublicKeyInfo of the certificate; `verify/2` accepts only a
  certificate with that pin and checks nothing else of it.
  """

  # The curve and the object identifiers of a P-256 key, its public key, and
  # its ECDSA signature with SHA-256.
  @curve :secp256r1
  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @ecdsa_sha256 {1, 2, 840, 10_045, 4, 3, 2}

  @dir "tls"
  @key_file "key.pem"
  @cert_file "cert.pem"

  # The wait of the TLS handshake of a connection
  # (`docs/features/remote-hands.md`, "Public listener").
  @handshake_ms 5_000

  @typedoc "The files of the listener and the pin of its certificate."
  @type t :: %{certfile: Path.t(), keyfile: Path.t(), pin: String.t()}

  @doc "The wait of the TLS handshake of a connection, in milliseconds."
  @spec handshake_ms() :: pos_integer()
  def handshake_ms, do: @handshake_ms

  @doc """
  The TLS files of the data folder `data_folder`, made at the first call.
  Gives `{:ok, %{certfile, keyfile, pin}}`, or `{:error, {:tls_file, path,
  reason}}` when a file that exists cannot be read as its part, and
  `{:error, {:tls_folder, reason}}` when the folder cannot be made.
  """
  @spec ensure(Path.t()) :: {:ok, t()} | {:error, term()}
  def ensure(data_folder) when is_binary(data_folder) do
    dir = Path.join(data_folder, @dir)
    files = %{keyfile: Path.join(dir, @key_file), certfile: Path.join(dir, @cert_file)}

    with :ok <- mkdir(dir) do
      case present(files) do
        :missing -> create(files)
        :present -> load(files)
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  The pin of a certificate: the base64url, without padding, of the SHA-256 of
  the DER of its SubjectPublicKeyInfo. `cert` is a DER certificate or the
  `:OTPCertificate` record that `:public_key.pkix_decode_cert/2` gives.
  """
  @spec pin(binary() | tuple()) :: String.t()
  def pin(cert), do: cert |> der() |> spki() |> then(&:crypto.hash(:sha256, &1)) |> encode()

  @doc """
  The check of a TLS peer: `{:valid, pin}` when `cert` has the pin, else
  `{:fail, :pin_mismatch}`. A chain, a name, and a date are not checked.
  """
  @spec verify(binary() | tuple(), String.t()) ::
          {:valid, String.t()} | {:fail, :pin_mismatch}
  def verify(cert, pin) do
    if pin(cert) == pin, do: {:valid, pin}, else: {:fail, :pin_mismatch}
  end

  @doc """
  The `verify_fun` of `:ssl.connect/3` for a pin: a chain that another party
  cannot verify is accepted, and the pin of the peer certificate decides.
  """
  @spec verify_fun() :: (term(), term(), String.t() -> {:valid, String.t()} | {:fail, term()})
  def verify_fun do
    fn
      cert, {:bad_cert, _reason}, pin -> verify(cert, pin)
      _cert, {:extension, _extension}, pin -> {:unknown, pin}
      cert, :valid, pin -> verify(cert, pin)
      cert, :valid_peer, pin -> verify(cert, pin)
    end
  end

  # The pair is missing only when both files are missing. One file alone is
  # an error: a new key would change the pin and leave the certificate of
  # the other file.
  defp present(%{keyfile: keyfile, certfile: certfile}) do
    case {File.stat(keyfile), File.stat(certfile)} do
      {{:error, :enoent}, {:error, :enoent}} ->
        :missing

      {{:ok, _}, {:error, :enoent}} ->
        {:error, {:tls_file, certfile, :enoent}}

      {{:error, :enoent}, {:ok, _}} ->
        {:error, {:tls_file, keyfile, :enoent}}

      {{:ok, _}, {:ok, _}} ->
        :present

      {{:error, reason}, _} ->
        {:error, {:tls_file, keyfile, reason}}

      {_, {:error, reason}} ->
        {:error, {:tls_file, certfile, reason}}
    end
  end

  defp load(%{keyfile: keyfile, certfile: certfile}) do
    with :ok <- chmod(keyfile, 0o600),
         {:ok, key_pem} <- read(keyfile),
         {:ok, cert_pem} <- read(certfile),
         {:ok, key} <- key(keyfile, key_pem),
         {:ok, cert} <- cert(certfile, cert_pem),
         :ok <- match(certfile, key, cert) do
      {:ok, %{keyfile: keyfile, certfile: certfile, pin: pin(cert)}}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tls_file, path, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:tls_file, path, reason}}
    end
  end

  defp key(path, pem) do
    with {:ok, [{:ECPrivateKey, _der, _encryption} = entry | _]} <- pem_entries(pem),
         {:ok, key} <- decode_entry(entry) do
      {:ok, key}
    else
      _bad -> {:error, {:tls_file, path, :bad_pem}}
    end
  end

  defp cert(path, pem) do
    with {:ok, [{:Certificate, der, :not_encrypted} | _]} <- pem_entries(pem),
         {:ok, _tbs} <- decoded(fn -> :public_key.pkix_decode_cert(der, :otp) end) do
      {:ok, der}
    else
      _bad -> {:error, {:tls_file, path, :bad_pem}}
    end
  end

  # `pem_decode/1` raises on a cut armor; that is the same error as a file
  # that it does not read.
  defp pem_entries(pem), do: decoded(fn -> :public_key.pem_decode(pem) end)

  defp decode_entry(entry) do
    decoded(fn -> :public_key.pem_entry_decode(entry) end)
  end

  # A valid armor with bad content raises in `:public_key`; it is the same
  # error as a file that `pem_decode/1` does not read.
  defp decoded(fun) do
    case fun.() do
      {:error, _reason} -> :error
      value -> {:ok, value}
    end
  rescue
    _bad -> :error
  catch
    _kind, _reason -> :error
  end

  # The certificate must belong to the key: a mismatch would serve a pin
  # that no peer can use with this key.
  defp match(path, key, cert) do
    if key_point(key) == cert_point(cert), do: :ok, else: {:error, {:tls_file, path, :mismatch}}
  end

  defp key_point(key) when elem(key, 0) == :ECPrivateKey, do: elem(key, 4)
  defp key_point(_key), do: :none

  defp cert_point(der) do
    with {:OTPCertificate, tbs, _algorithm, _signature} <- :public_key.pkix_decode_cert(der, :otp),
         {:OTPSubjectPublicKeyInfo, _algorithm, {:ECPoint, point}} <- elem(tbs, 7) do
      point
    else
      _other -> :none
    end
  rescue
    _bad -> :none
  end

  defp create(files) do
    key = :public_key.generate_key({:namedCurve, @curve})
    cert = certificate(key)
    key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    cert_pem = :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])

    with :ok <- write_key(files.keyfile, key_pem),
         :ok <- write(files.certfile, cert_pem, 0o644) do
      {:ok, Map.put(files, :pin, pin(cert))}
    end
  end

  # The key file is 0600 before its first byte: the chmod runs on the open
  # file, which holds no key yet.
  defp write_key(path, data) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        try do
          with :ok <- File.chmod(path, 0o600) do
            IO.binwrite(device, data)
          end
        after
          File.close(device)
        end

      {:error, :eexist} ->
        {:error, {:tls_file, path, :eexist}}

      {:error, reason} ->
        {:error, {:tls_file, path, reason}}
    end
  end

  defp write(path, data, mode) do
    case File.write(path, data, [:binary]) do
      :ok -> File.chmod(path, mode)
      error -> error
    end
  end

  # A self-signed certificate of the key: one name, one serial, and a life
  # that a peer ignores (it checks the pin only).
  defp certificate(key) do
    point = elem(key, 4)
    algorithm = {:PublicKeyAlgorithm, @ec_public_key, {:namedCurve, @p256}}
    spki = {:OTPSubjectPublicKeyInfo, algorithm, {:ECPoint, point}}
    name = {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "helyx"}}]]}

    validity =
      {:Validity, {:utcTime, ~c"200101000000Z"}, {:utcTime, ~c"400101000000Z"}}

    tbs =
      {:OTPTBSCertificate, :v3, 1, signature_algorithm(), name, validity, name, spki,
       :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}

    :public_key.pkix_sign(tbs, key)
  end

  defp signature_algorithm,
    do: {:SignatureAlgorithm, @ecdsa_sha256, :asn1_NOVALUE}

  # The folder and its files: no other user reads the key.
  defp mkdir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:tls_folder, reason}}
    end
  end

  defp der({:OTPCertificate, _tbs, _algorithm, _signature} = cert),
    do: :public_key.pkix_encode(:OTPCertificate, cert, :otp)

  defp der(der) when is_binary(der), do: der

  defp spki(der) do
    {:OTPCertificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(der, :otp)

    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, oid, params}, {:ECPoint, point}} =
      elem(tbs, 7)

    :public_key.der_encode(
      :SubjectPublicKeyInfo,
      {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, oid, params}, point}
    )
  end

  defp encode(hash), do: Base.url_encode64(hash, padding: false)
end
