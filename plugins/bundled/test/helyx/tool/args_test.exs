defmodule Helyx.Tool.ArgsTest do
  # The check of a tool's arguments from the schema of `parameters/0`:
  # each supported keyword, the `null` rule, and a keyword that it does not
  # know (`Helyx.Tool.Args`).
  use ExUnit.Case, async: true

  alias Helyx.Tool.Args

  defp schema(properties, required \\ []) do
    %{"type" => "object", "properties" => properties, "required" => required}
  end

  test "type checks the value of each property" do
    schema =
      schema(
        %{
          "text" => %{"type" => "string"},
          "count" => %{"type" => "integer"},
          "size" => %{"type" => "number"},
          "on" => %{"type" => "boolean"}
        },
        ~w(text count size on)
      )

    assert Args.check(
             %{"text" => "a", "count" => 1, "size" => 1.5, "on" => false},
             schema
           ) == {:ok, %{"text" => "a", "count" => 1, "size" => 1.5, "on" => false}}

    assert Args.check(%{"text" => 1, "count" => 1, "size" => 1, "on" => true}, schema) ==
             {:error, "text must be a string"}

    assert Args.check(%{"text" => "a", "count" => 1.5, "size" => 1, "on" => true}, schema) ==
             {:error, "count must be an integer"}

    assert Args.check(%{"text" => "a", "count" => 1, "size" => "1", "on" => true}, schema) ==
             {:error, "size must be a number"}

    assert Args.check(%{"text" => "a", "count" => 1, "size" => 1, "on" => "yes"}, schema) ==
             {:error, "on must be true or false"}
  end

  test "properties and required check a nested object, and keep the unknown keys" do
    schema =
      schema(%{
        "item" => %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}},
          "required" => ["label"]
        }
      })

    assert Args.check(%{"item" => %{"label" => "a", "other" => 1}}, schema) ==
             {:ok, %{"item" => %{"label" => "a", "other" => 1}}}

    assert Args.check(%{"item" => %{}}, schema) == {:error, "item.label is required"}

    assert Args.check(%{"item" => %{"label" => 7}}, schema) ==
             {:error, "item.label must be a string"}
  end

  test "a required property that is missing or null is an error" do
    schema = schema(%{"path" => %{"type" => "string"}}, ["path"])

    assert Args.check(%{}, schema) == {:error, "path is required"}
    assert Args.check(%{"path" => nil}, schema) == {:error, "path is required"}
    assert Args.check(%{"path" => "a"}, schema) == {:ok, %{"path" => "a"}}
  end

  test "an optional property that is null is absent, so its default applies" do
    schema =
      schema(%{
        "offset" => %{"type" => "integer", "minimum" => 1, "default" => 1},
        "note" => %{"type" => "string"}
      })

    assert Args.check(%{}, schema) == {:ok, %{"offset" => 1}}
    assert Args.check(%{"offset" => nil}, schema) == {:ok, %{"offset" => 1}}
    assert Args.check(%{"note" => nil}, schema) == {:ok, %{"offset" => 1}}

    assert Args.check(%{"offset" => 2, "note" => "a"}, schema) ==
             {:ok, %{"offset" => 2, "note" => "a"}}
  end

  test "enum lists the values that the property takes" do
    schema = schema(%{"disposition" => %{"type" => "string", "enum" => ~w(prompt steer)}})

    assert Args.check(%{"disposition" => "steer"}, schema) ==
             {:ok, %{"disposition" => "steer"}}

    assert Args.check(%{"disposition" => "shout"}, schema) ==
             {:error, "disposition must be one of prompt, steer"}

    assert Args.check(%{"disposition" => 1}, schema) ==
             {:error, "disposition must be a string"}
  end

  test "minimum and maximum bound an integer or a number" do
    schema =
      schema(%{
        "from" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
        "least" => %{"type" => "integer", "minimum" => 1},
        "most" => %{"type" => "number", "maximum" => 2}
      })

    assert Args.check(%{"from" => 1, "least" => 1, "most" => 2}, schema) ==
             {:ok, %{"from" => 1, "least" => 1, "most" => 2}}

    assert Args.check(%{"from" => 0, "least" => 1, "most" => 1}, schema) ==
             {:error, "from must be an integer from 1 to 10"}

    assert Args.check(%{"from" => 11, "least" => 1, "most" => 1}, schema) ==
             {:error, "from must be an integer from 1 to 10"}

    assert Args.check(%{"from" => 1, "least" => 0, "most" => 1}, schema) ==
             {:error, "least must be an integer of 1 or more"}

    assert Args.check(%{"from" => 1, "least" => 1, "most" => 3}, schema) ==
             {:error, "most must be a number of 2 or less"}
  end

  test "minLength and maxLength bound a string in bytes" do
    schema =
      schema(%{
        "text" => %{"type" => "string", "minLength" => 1, "maxLength" => 3},
        "short" => %{"type" => "string", "maxLength" => 2}
      })

    assert Args.check(%{"text" => "é", "short" => ""}, schema) ==
             {:ok, %{"text" => "é", "short" => ""}}

    assert Args.check(%{"text" => "", "short" => ""}, schema) ==
             {:error, "text must be a string of 1 to 3 bytes"}

    assert Args.check(%{"text" => "éé", "short" => ""}, schema) ==
             {:error, "text must be a string of 1 to 3 bytes"}

    assert Args.check(%{"text" => "a", "short" => "abc"}, schema) ==
             {:error, "short must be a string of at most 2 bytes"}
  end

  test "items bounds and checks each item of a list" do
    schema =
      schema(%{
        "ids" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "minItems" => 1,
          "maxItems" => 2
        }
      })

    assert Args.check(%{"ids" => ["a", "b"]}, schema) == {:ok, %{"ids" => ["a", "b"]}}

    assert Args.check(%{"ids" => []}, schema) ==
             {:error, "ids must be a list of 1 to 2 items"}

    assert Args.check(%{"ids" => ["a", "b", "c"]}, schema) ==
             {:error, "ids must be a list of 1 to 2 items"}

    assert Args.check(%{"ids" => ["a", 2]}, schema) ==
             {:error, "ids[1] must be a string"}

    assert Args.check(%{"ids" => "a"}, schema) == {:error, "ids must be a list"}
  end

  test "a default fills a nullable property of an object of a list" do
    schema =
      schema(%{
        "questions" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{"multi_select" => %{"type" => "boolean", "default" => false}},
            "required" => ["question"]
          }
        }
      })

    item = %{"question" => "Which?"}

    assert Args.check(%{"questions" => [item]}, schema) ==
             {:ok, %{"questions" => [Map.put(item, "multi_select", false)]}}

    assert Args.check(%{"questions" => [Map.put(item, "multi_select", nil)]}, schema) ==
             {:ok, %{"questions" => [Map.put(item, "multi_select", false)]}}
  end

  test "description is read and states no rule" do
    schema = schema(%{"path" => %{"type" => "string", "description" => "a file"}})
    assert Args.check(%{"path" => "a"}, schema) == {:ok, %{"path" => "a"}}
  end

  test "an unknown keyword raises at the first call" do
    schema = schema(%{"path" => %{"type" => "string", "pattern" => "^a"}})

    assert_raise ArgumentError, ~r/unknown schema keyword "pattern" at path/, fn ->
      Args.check(%{"path" => "a"}, schema)
    end
  end

  test "an unknown type, and a rule on another type, raise" do
    assert_raise ArgumentError, ~r/unknown schema type "date"/, fn ->
      Args.check(%{}, schema(%{"at" => %{"type" => "date"}}))
    end

    assert_raise ArgumentError, ~r/"minimum" does not fit the type "string"/, fn ->
      Args.check(%{}, schema(%{"at" => %{"type" => "string", "minimum" => 1}}))
    end
  end
end
