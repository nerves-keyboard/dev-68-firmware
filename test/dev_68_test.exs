defmodule Dev68Test do
  use ExUnit.Case
  doctest Dev68

  test "greets the world" do
    assert Dev68.hello() == :world
  end
end
