# Disposable loopback HTTP/TLS fixture primitives shared by the Ruby protocol fixtures.
#
# The fixtures need the subset of behavior the previous http.server based fixtures
# provided: one thread per connection, HTTP/1.1 keep-alive, duplicate headers,
# chunked request and response framing, raw interim writes and abortive closes.

require "base64"
require "json"
require "openssl"
require "socket"
require "stringio"
require "time"
require "timeout"
require "zlib"

Thread.report_on_exception = false

module FixtureHTTP
  CRLF = "\r\n"

  REASONS = {
    100 => "Continue",
    101 => "Switching Protocols",
    103 => "Early Hints",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    204 => "No Content",
    302 => "Found",
    304 => "Not Modified",
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    418 => "I'm a Teapot",
    500 => "Internal Server Error",
    502 => "Bad Gateway",
    599 => "Unknown"
  }.freeze

  class Error < StandardError; end

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.gzip(data)
    output = StringIO.new("".b)
    writer = Zlib::GzipWriter.new(output)
    writer.mtime = 0
    writer.write(data)
    writer.finish
    output.string.b
  end

  def self.deflate(data)
    Zlib::Deflate.deflate(data).b
  end

  def self.tls_context(certificate, key)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = OpenSSL::X509::Certificate.new(File.read(certificate))
    context.key = OpenSSL::PKey.read(File.read(key))
    context
  end

  def self.refused_port
    socket = TCPServer.new("127.0.0.1", 0)
    port = socket.addr[1]
    socket.close
    port
  end

  def self.read_line(io)
    line = io.gets("\n")
    return nil if line.nil?

    line.sub(/\r?\n\z/, "")
  end

  def self.read_exact(io, count)
    data = "".b
    while data.bytesize < count
      chunk = io.read(count - data.bytesize)
      raise EOFError, "unexpected end of stream" if chunk.nil? || chunk.empty?

      data << chunk
    end
    data
  end

  def self.read_chunked(io)
    data = "".b
    loop do
      line = read_line(io)
      raise EOFError, "missing chunk size" if line.nil?

      size = line.split(";", 2)[0].to_i(16)
      if size.zero?
        loop do
          trailer = read_line(io)
          break if trailer.nil? || trailer.empty?
        end
        return data
      end
      data << read_exact(io, size)
      read_exact(io, 2)
    end
  end

  # Ordered, case-insensitive header collection that keeps duplicate fields.
  class Headers
    include Enumerable

    def initialize(entries = [])
      @entries = entries
    end

    def add(name, value)
      @entries << [name, value]
      self
    end

    def get(name, default = nil)
      entry = @entries.find { |key, _| key.casecmp(name.to_s).zero? }
      entry ? entry[1] : default
    end

    def get_all(name)
      @entries.select { |key, _| key.casecmp(name.to_s).zero? }.map { |_, value| value }
    end

    def include?(name)
      @entries.any? { |key, _| key.casecmp(name.to_s).zero? }
    end

    def each(&block)
      @entries.each(&block)
    end

    def raw_items
      @entries.map { |key, value| [key, value] }
    end
    alias to_a raw_items
    alias items raw_items
  end

  class Request
    attr_reader :method, :target, :version, :headers

    def initialize(io, method, target, version, headers)
      @io = io
      @method = method
      @target = target
      @version = version
      @headers = headers
      @body = nil
    end

    def persistent?
      connection = @headers.get("Connection").to_s.downcase
      return false if connection == "close"
      return true if connection == "keep-alive"

      @version == "HTTP/1.1"
    end

    # Bodies are read lazily because streaming fixtures answer before the upload ends.
    def body
      @body ||= read_body
    end

    private

    def read_body
      if @headers.get("Transfer-Encoding").to_s.downcase.include?("chunked")
        FixtureHTTP.read_chunked(@io)
      else
        length = @headers.get("Content-Length", "0").to_i
        length.positive? ? FixtureHTTP.read_exact(@io, length) : "".b
      end
    end
  end

  # Per-request view mirroring the small http.server handler surface the fixtures used.
  class Exchange
    attr_accessor :close_connection
    attr_reader :request, :status

    def initialize(io, request)
      @io = io
      @request = request
      @status = nil
      @reason = nil
      @headers = []
      @close_connection = !request.persistent?
    end

    def command
      @request.method
    end

    def path
      @request.target
    end

    def headers
      @request.headers
    end

    def request_body
      @request.body
    end

    def send_response(code, reason = nil)
      @status = code
      @reason = reason || REASONS[code] || ""
      @headers << ["Server", "Fixture/1.0"]
      @headers << ["Date", Time.now.httpdate]
    end

    def send_header(name, value)
      @headers << [name, value.to_s]
      nil
    end

    def end_headers
      head = "HTTP/1.1 #{@status} #{@reason}#{CRLF}"
      @headers.each { |name, value| head << "#{name}: #{value}#{CRLF}" }
      head << CRLF
      @io.write(head)
      @io.flush
      nil
    end

    def write(data)
      @io.write(data)
      nil
    end

    def flush
      @io.flush
      nil
    end

    # Abortive close: SO_LINGER(1, 0) makes the peer observe a reset.
    def abort_reset
      @close_connection = true
      begin
        @io.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      rescue StandardError
        # Socket already gone.
      end
      begin
        @io.close
      rescue StandardError
        # Already closed.
      end
      nil
    end
  end

  # Threaded loopback server. TLS handshakes run per connection like the prior fixtures.
  class Server
    attr_reader :port

    def initialize(handler, tls: nil)
      @handler = handler
      @tls = tls
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @closed = false
      @thread = nil
    end

    def start
      @thread = Thread.new do
        until @closed
          begin
            client = @tcp.accept
          rescue IOError, Errno::EBADF
            break
          rescue StandardError
            next
          end
          Thread.new(client) { |socket| accept_client(socket) }
        end
      end
      self
    end

    def shutdown
      @closed = true
      begin
        @tcp.close
      rescue StandardError
        # Already closed.
      end
      nil
    end

    private

    def accept_client(socket)
      if @tls
        secure = OpenSSL::SSL::SSLSocket.new(socket, @tls)
        secure.sync_close = true
        begin
          secure.accept
        rescue StandardError
          begin
            secure.close
          rescue StandardError
            # Handshake peer vanished.
          end
          return
        end
        socket = secure
      end
      serve(socket)
    end

    def serve(socket)
      socket.sync = true if socket.respond_to?(:sync=)
      loop do
        request = read_request(socket)
        break if request.nil?

        exchange = Exchange.new(socket, request)
        @handler.new(exchange).respond
        exchange.flush
        break if exchange.close_connection
      end
    rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError, ArgumentError
      # Disposable client aborted the connection.
    ensure
      begin
        socket.close
      rescue StandardError
        # Already closed.
      end
    end

    def read_request(socket)
      line = FixtureHTTP.read_line(socket)
      return nil if line.nil? || line.empty?

      parts = line.split(" ")
      raise ArgumentError, "malformed request line" unless parts.length == 3

      headers = Headers.new
      loop do
        field = FixtureHTTP.read_line(socket)
        raise EOFError, "truncated request head" if field.nil?
        break if field.empty?

        name, value = field.split(":", 2)
        raise ArgumentError, "malformed request header" if value.nil?

        headers.add(name, value.sub(/\A[ \t]*/, ""))
      end
      Request.new(socket, parts[0], parts[1], parts[2], headers)
    end
  end

  # Raw TCP server that holds each connection open for the configured stall time.
  class StallServer
    attr_reader :port

    def initialize(seconds)
      @seconds = seconds
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @closed = false
      @thread = nil
    end

    def start
      @thread = Thread.new do
        until @closed
          begin
            client = @tcp.accept
          rescue IOError, Errno::EBADF
            break
          rescue StandardError
            next
          end
          Thread.new(client) do |socket|
            begin
              sleep(@seconds)
            ensure
              begin
                socket.close
              rescue StandardError
                # Peer vanished.
              end
            end
          end
        end
      end
      self
    end

    def shutdown
      @closed = true
      begin
        @tcp.close
      rescue StandardError
        # Already closed.
      end
      nil
    end
  end

  # Raw TCP server that drains input until the peer closes or a read stalls.
  class DrainServer
    attr_reader :port

    def initialize(idle_seconds = 5)
      @idle_seconds = idle_seconds
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @closed = false
      @thread = nil
    end

    def start
      @thread = Thread.new do
        until @closed
          begin
            client = @tcp.accept
          rescue IOError, Errno::EBADF
            break
          rescue StandardError
            next
          end
          Thread.new(client) do |socket|
            begin
              loop do
                break unless IO.select([socket], nil, nil, @idle_seconds)

                socket.readpartial(4096)
              end
            rescue EOFError, IOError, SystemCallError
              # Peer closed or reset.
            ensure
              begin
                socket.close
              rescue StandardError
                # Peer vanished.
              end
            end
          end
        end
      end
      self
    end

    def shutdown
      @closed = true
      begin
        @tcp.close
      rescue StandardError
        # Already closed.
      end
      nil
    end
  end

  # Minimal HTTP/1.1 client; framing stays observable instead of being normalized.
  def self.request(port, method, path, headers = [], body: nil, chunks: nil,
                   host: nil, accept_encoding: nil, close: false, timeout: 10)
    socket = TCPSocket.new("127.0.0.1", port)
    begin
      Timeout.timeout(timeout) do
        names = headers.map { |name, _| name.downcase }
        head = "#{method} #{path} HTTP/1.1#{CRLF}"
        head << "Host: #{host}#{CRLF}" if host && !names.include?("host")
        head << "Accept-Encoding: #{accept_encoding}#{CRLF}" if accept_encoding && !names.include?("accept-encoding")
        head << "Connection: close#{CRLF}" if close && !names.include?("connection")
        headers.each { |name, value| head << "#{name}: #{value}#{CRLF}" }
        if chunks
          head << "Transfer-Encoding: chunked#{CRLF}"
        elsif body
          head << "Content-Length: #{body.bytesize}#{CRLF}"
        end
        head << CRLF
        socket.write(head)
        socket.write(body) if body
        if chunks
          chunks.each do |chunk|
            socket.write(chunk.bytesize.to_s(16) + CRLF + chunk + CRLF)
          end
          socket.write("0#{CRLF}#{CRLF}")
        end
        socket.flush
        read_response(socket, method)
      end
    ensure
      begin
        socket.close
      rescue StandardError
        # Already closed.
      end
    end
  rescue Timeout::Error
    raise Error, "response timed out for #{path}"
  end

  def self.read_head(socket)
    loop do
      line = read_line(socket)
      raise Error, "empty response" if line.nil?

      parts = line.split(" ", 3)
      raise Error, "malformed status line: #{line}" unless parts[1].to_s.match?(/\A\d+\z/)

      code = parts[1].to_i
      headers = []
      loop do
        field = read_line(socket)
        raise Error, "truncated response head" if field.nil?
        break if field.empty?

        name, value = field.split(":", 2)
        raise Error, "malformed response header" if value.nil?

        headers << [name, value.sub(/\A[ \t]*/, "")]
      end
      next if code >= 100 && code < 200 && code != 101

      return [code, headers]
    end
  end

  def self.read_body(socket, code, headers, method)
    return "".b if method == "HEAD" || code == 204 || code == 304 || code == 101

    table = {}
    headers.each { |name, value| table[name.downcase] = value }
    if table["transfer-encoding"].to_s.downcase.include?("chunked")
      return read_chunked(socket)
    end
    if table["content-length"]
      return read_exact(socket, table["content-length"].to_i)
    end

    socket.read || "".b
  end

  def self.read_response(socket, method = "GET")
    code, headers = read_head(socket)
    [code, headers, read_body(socket, code, headers, method)]
  end

  # Child process handle with poll/wait semantics matching the previous drivers.
  class Child
    attr_reader :pid

    def initialize(executable, environment = {})
      @pid = Process.spawn(environment, executable)
      @status = nil
    end

    def poll
      return @status if @status

      pid, status = Process.waitpid2(@pid, Process::WNOHANG)
      @status = status if pid
      @status
    end

    def running?
      poll.nil?
    end

    def wait(seconds)
      deadline = FixtureHTTP.monotonic + seconds
      loop do
        status = poll
        return status if status
        raise Error, "process did not exit within #{seconds}s" if FixtureHTTP.monotonic > deadline

        sleep 0.01
      end
    end

    def kill(signal = "KILL")
      Process.kill(signal, @pid)
    rescue StandardError
      nil
    end

    def exitstatus
      @status && @status.exitstatus
    end
  end
end
