defmodule Helyx.Transport.WebSocket.TLS do
  @moduledoc """
  The key, the certificate, and the pin of the public listener of the wire
  (`docs/features/remote-hands.md`, "Pairing and the public listener").

  `ensure/1` makes an ECDSA P-256 key and a self-signed certificate on the
  first start with `--public`, under `<data folder>/tls/`, and reads them on
  every later start. The key file has mode 0600. The pin is the base64url,
  without padding, of the SHA-256 of the DER of the SubjectPublicKeyInfo of
  the certificate; `verify/2` accepts only a certificate with that pin and
  checks nothing else of it.

  Nothing in this module names a peer or a link: `Helyx.Transport.WebSocket.
  Pairing` does that.
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

  @typedoc "The files of the listener and the pin of its certificate."
  @type t :: %{certfile: Path.t(), keyfile: Path.t(), pin: String.t()}

  @doc """
  The TLS files of the data folder `data_folder`, made at the first call.
  Gives `{:ok, %{certfile, keyfile, pin}}`, or `{:error, reason}` when the
  folder or a file cannot be made or read.
  """
  @spec ensure(Path.t()) :: {:ok, t()} | {:error, term()}
  def ensure(data_folder) when is_binary(data_folder) do
    dir = Path.join(data_folder, @dir)
    files = %{keyfile: Path.join(dir, @key_file), certfile: Path.join(dir, @cert_file)}

    with :ok <- mkdir(dir) do
      case read(files) do
        {:ok, tls} -> {:ok, tls}
        :error -> create(files)
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

  defp read(%{keyfile: keyfile, certfile: certfile}) do
    with {:ok, key_pem} <- File.read(keyfile),
         {:ok, cert_pem} <- File.read(certfile),
         {:ok, _key} <- key(key_pem),
         {:ok, cert} <- cert(cert_pem) do
      {:ok, %{keyfile: keyfile, certfile: certfile, pin: pin(cert)}}
    else
      _missing_or_bad -> :error
    end
  end

  defp key(pem) do
    case :public_key.pem_decode(pem) do
      [{type, _der, _encryption} = entry | _] when type == :ECPrivateKey ->
        {:ok, :public_key.pem_entry_decode(entry)}

      _other ->
        :error
    end
  end

  defp cert(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted} | _] -> {:ok, der}
      _other -> :error
    end
  end

  defp create(files) do
    key = :public_key.generate_key({:namedCurve, @curve})
    cert = certificate(key)
    key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    cert_pem = :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])

    with :ok <- write(files.keyfile, key_pem, 0o600),
         :ok <- write(files.certfile, cert_pem, 0o644) do
      {:ok, Map.put(files, :pin, pin(cert))}
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

  defp write(path, data, mode) do
    with :ok <- File.write(path, data, [:binary]) do
      File.chmod(path, mode)
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:tls_folder, :file.format_error(reason)}}
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
