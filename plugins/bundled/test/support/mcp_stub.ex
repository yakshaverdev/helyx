defmodule Helyx.Test.MCPStub do
  @moduledoc false
  # A stub MCP server for the tests of `Helyx.Tool.MCP`: a perl program
  # (perl is a requirement of Helyx) that speaks JSON-RPC lines on stdio as
  # its spec says. It never reaches the network.
  #
  # The spec, a map written as JSON beside the program:
  #   * "version": the protocolVersion of its initialize answer.
  #   * "pages": the pages of its first tools/list, each a list of tools.
  #   * "cursor": the nextCursor of a first listing, in place of its own.
  #   * "relist": the pages of every later tools/list, or null for none:
  #     a later tools/list gets no answer.
  #   * "requests": requests that it sends after notifications/initialized,
  #     each a JSON-RPC request; the answers go to "log".
  #   * "env": names whose value it writes to "log" as {"env": {name: value
  #     or null}} at its start, so a test checks those names only.
  #   * "log": a file that gets one JSON line per answer of the client to a
  #     request of the stub, and the "env" line.
  # Calls: "echo" answers its arguments as text; "fail" answers isError;
  # "changed" sends notifications/tools/list_changed, then answers "ok".

  @script ~S"""
  use strict;
  use warnings;
  use JSON::PP;
  $| = 1;
  my $json = JSON::PP->new->canonical;
  open(my $fh, '<', $ARGV[0]) or die;
  my $spec = $json->decode(do { local $/; <$fh> });
  close($fh);
  my $listed = 0;
  sub out { print $json->encode($_[0]), "\n"; }
  sub logline {
    return unless $spec->{log};
    open(my $l, '>>', $spec->{log}) or die;
    print $l $json->encode($_[0]), "\n";
    close($l);
  }
  if ($spec->{env}) {
    my %seen = map { $_ => (defined $ENV{$_} ? $ENV{$_} : undef) } @{$spec->{env}};
    logline({env => \%seen});
  }
  while (my $line = <STDIN>) {
    my $msg = eval { $json->decode($line) } or next;
    my $method = $msg->{method};
    my $id = $msg->{id};
    if (!defined $method) { logline($msg); next; }
    if ($method eq 'initialize') {
      out({jsonrpc => '2.0', id => $id, result => {protocolVersion => $spec->{version},
        capabilities => {tools => {listChanged => JSON::PP::true}}, serverInfo => {name => 'stub', version => '1'}}});
    } elsif ($method eq 'notifications/initialized') {
      out($_) for @{$spec->{requests} || []};
    } elsif ($method eq 'tools/list') {
      my $first = !$listed;
      my $pages = $listed ? $spec->{relist} : $spec->{pages};
      next unless defined $pages;
      my $at = defined $msg->{params}{cursor} ? $msg->{params}{cursor} : 0;
      my $result = {tools => $pages->[$at]};
      if ($at + 1 < @$pages) { $result->{nextCursor} = "" . ($at + 1); } else { $listed = 1; }
      $result->{nextCursor} = $spec->{cursor} if exists $spec->{cursor} && $first;
      out({jsonrpc => '2.0', id => $id, result => $result});
    } elsif ($method eq 'tools/call') {
      my $name = $msg->{params}{name};
      my $args = $msg->{params}{arguments};
      if ($name eq 'echo') {
        out({jsonrpc => '2.0', id => $id, result => {content => [{type => 'text', text => 'echo ' . $json->encode($args)}]}});
      } elsif ($name eq 'fail') {
        out({jsonrpc => '2.0', id => $id, result => {isError => JSON::PP::true, content => [{type => 'text', text => 'failed'}]}});
      } elsif ($name eq 'changed') {
        out({jsonrpc => '2.0', method => 'notifications/tools/list_changed'});
        out({jsonrpc => '2.0', id => $id, result => {content => [{type => 'text', text => 'ok'}]}});
      } else {
        out({jsonrpc => '2.0', id => $id, error => {code => -32602, message => "unknown tool $name"}});
      }
    }
  }
  """

  # A tool of the stub's listing.
  def tool(name, extra \\ %{}),
    do: Map.merge(%{"name" => name, "inputSchema" => %{"type" => "object"}}, extra)

  # The config entry of a stub with `spec`, its program and spec in `dir`.
  def server(dir, spec) do
    id = System.unique_integer([:positive])
    script = Path.join(dir, "stub-#{id}.pl")
    spec_path = Path.join(dir, "stub-#{id}.json")
    File.write!(script, @script)
    spec = Map.merge(%{"version" => "2025-06-18", "pages" => [[tool("echo")]]}, spec)
    File.write!(spec_path, JSON.encode!(spec))
    %{"command" => System.find_executable("perl"), "args" => [script, spec_path]}
  end

  # Writes the MCP config of `servers` (a map of name to entry), mode 0600,
  # and returns its path.
  def config(dir, servers) do
    path = Path.join(dir, "mcp.json")
    File.write!(path, JSON.encode!(%{"mcpServers" => servers}))
    File.chmod!(path, 0o600)
    path
  end

  # The JSON lines of a stub's log.
  def log(path) do
    case File.read(path) do
      {:ok, text} -> for line <- String.split(text, "\n", trim: true), do: JSON.decode!(line)
      {:error, :enoent} -> []
    end
  end
end
