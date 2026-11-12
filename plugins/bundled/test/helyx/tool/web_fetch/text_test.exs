defmodule Helyx.Tool.WebFetch.TextTest do
  # The text of an HTML page: the elements that go with their content, the
  # blocks and `br` as new lines, the link targets, the entities, and the
  # blank runs (`Helyx.Tool.WebFetch.Text`, `docs/features/web-fetch.md`).
  use ExUnit.Case, async: true

  alias Helyx.Tool.WebFetch.Text

  defp text(html), do: Text.to_text(html)

  test "a script, a style, a noscript, an svg, and a comment go with their content" do
    html = """
    <html><head><style>p { color: red }</style></head>
    <body><script>alert("x")</script><noscript>no js</noscript>
    <svg><text>vector</text></svg><!-- hidden <p>p</p> -->
    <p>shown</p></body></html>
    """

    assert text(html) == "shown"
  end

  test "the title is a line of the text, also in a head that has no close tag" do
    assert text("<html><head><title>Docs</title><meta charset=utf-8><body><p>shown</p>") ==
             "Docs\n\nshown"
  end

  test "a script that holds the close tag of another element ends at its own" do
    assert text("<script>if (a < b) {}</div><p>x</p></script><p>after</p>") == "after"
  end

  test "a block tag and br start a new line, so two blocks are apart" do
    assert text("<div>a</div><div>b</div>") == "a\n\nb"
    assert text("a<br>b") == "a\nb"
    assert text("<ul><li>one</li><li>two</li></ul>") == "one\n\ntwo"
  end

  test "the common entities and the numeric ones decode, and another stays as text" do
    assert text("<p>&amp; &lt; &gt; &quot; &#39; &nbsp;x</p>") == ~s|& < > " ' x|
    assert text("<p>&#65;&#x42;</p>") == "AB"

    assert text("<p>&unknown; &#xD800; &#0; &#x110000;</p>") ==
             "&unknown; &#xD800; &#0; &#x110000;"
  end

  test "a link keeps its target after its text" do
    assert text("<p>See <a href=\"/d?a=1&amp;b=2\">the docs</a>.</p>") ==
             "See the docs (/d?a=1&b=2)."

    assert text("<p><a href=\"http://e.com\">e</a></p>") == "e (http://e.com)"
    assert text("<p><a href=\"/x\"></a>none</p>") == "none"
    assert text("<p><a>bare</a> and <a href=\"/y\">y</a></p>") == "bare and y (/y)"
  end

  test "an attribute value is read in double quotes, single quotes, and bare" do
    assert text("<a href='/a'>s</a>") == "s (/a)"
    assert text("<a href=/b>s</a>") == "s (/b)"
    assert text(~s|<a class="x" href="/c" id=y>s</a>|) == "s (/c)"
  end

  test "a nested tag and a tag that never closes keep the text" do
    assert text("<div><p>a <b>bold</b> and <i>it</i></p></div>") == "a bold and it"
    assert text("<div><p>a") == "a"
    assert text("<p>a<p>b") == "a\nb"
  end

  test "blank runs collapse to one, and the text has no blank line at its ends" do
    assert text("<p>a</p>\n\n\n<p></p>\n\n<p>b</p>") == "a\n\nb"
    assert text("\n\n<p>a</p>\n\n") == "a"
  end

  test "the spaces of a line become one, and its ends are trimmed" do
    assert text("<p>  a\t\tb \r\n c  </p>") == "a b\nc"
    assert text("<p>a   b</p>") == "a b"
  end

  test "a tag name is case-insensitive" do
    assert text("<P>A</P><SCRIPT>x</SCRIPT><P>B</P>") == "A\n\nB"
  end

  test "a doctype, a self-closing tag, and a page with no tag keep what they hold" do
    assert text("<!DOCTYPE html><p>a</p>") == "a"
    assert text("<p>a<img src=x /><input value=1>b</p>") == "ab"
    assert text("plain text") == "plain text"
    assert text("") == ""
  end
end
