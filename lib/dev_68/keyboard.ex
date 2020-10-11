defmodule Dev68.Keyboard do
  # This matrix initializes all columns as outputs (default LOW) and all rows as
  # inputs. It scans over the columns and sets them to HIGH, then scans over the
  # rows and reads.

  use GenServer

  alias Dev68.Utils

  alias Circuits.GPIO

  @matrix_layout [
    [:k001, :k002, :k003, :k004, :k005, :k006, :k007, :k008],
    [:k017, :k018, :k019, :k020, :k021, :k022, :k023, :k024],
    [:k033, :k034, :k035, :k036, :k037, :k038, :k039, :k040],
    [:k046, :k047, :k048, :k049, :k050, :k051, :k052, :k053],
    [:k059, :k060, :k061, :none, :none, :k062, :none, :none],
    [:k068, :k067, :k066, :none, :k065, :k064, :k063, :none],
    [:none, :k058, :k057, :none, :none, :k056, :k055, :k054],
    [:none, :none, :k045, :none, :k044, :k043, :k042, :k041],
    [:k032, :k031, :k030, :k029, :k028, :k027, :k026, :k025],
    [:k016, :k015, :k014, :k013, :k012, :k011, :k010, :k009]
  ]

  # See `rootfs_overlay/etc/config-pin/bbbw-matrix.conf` for where these numbers
  # came from. If you're using PocketBeagle, change these numbers to match
  # `rootfs_overlay/etc/config-pin/pocket.conf` instead.
  @row_pins [70, 71, 72, 73, 74, 75, 76, 77, 86, 87]
  @col_pins [110, 111, 112, 113, 7, 115, 20, 117]

  @debounce_window 10

  # this file exists because `/etc/pre-run.sh` set it up during boot.
  @hid_device "/dev/hidg0"

  @keymap [
    # Layer 0:
    %{
      k001: AFK.Keycode.Key.new(:escape),
      k002: AFK.Keycode.Key.new(:"1"),
      k003: AFK.Keycode.Key.new(:"2"),
      k004: AFK.Keycode.Key.new(:"3"),
      k005: AFK.Keycode.Key.new(:"4"),
      k006: AFK.Keycode.Key.new(:"5"),
      k007: AFK.Keycode.Key.new(:"6"),
      k008: AFK.Keycode.Key.new(:"7"),
      k009: AFK.Keycode.Key.new(:"8"),
      k010: AFK.Keycode.Key.new(:"9"),
      k011: AFK.Keycode.Key.new(:"0"),
      k012: AFK.Keycode.Key.new(:minus),
      k013: AFK.Keycode.Key.new(:equals),
      k014: AFK.Keycode.Key.new(:backspace),
      k015: AFK.Keycode.Key.new(:home),
      k016: AFK.Keycode.Key.new(:page_up),
      #
      k017: AFK.Keycode.Key.new(:tab),
      k018: AFK.Keycode.Key.new(:q),
      k019: AFK.Keycode.Key.new(:w),
      k020: AFK.Keycode.Key.new(:e),
      k021: AFK.Keycode.Key.new(:r),
      k022: AFK.Keycode.Key.new(:t),
      k023: AFK.Keycode.Key.new(:y),
      k024: AFK.Keycode.Key.new(:u),
      k025: AFK.Keycode.Key.new(:i),
      k026: AFK.Keycode.Key.new(:o),
      k027: AFK.Keycode.Key.new(:p),
      k028: AFK.Keycode.Key.new(:left_square_bracket),
      k029: AFK.Keycode.Key.new(:right_square_bracket),
      k030: AFK.Keycode.Key.new(:backslash),
      k031: AFK.Keycode.Key.new(:end),
      k032: AFK.Keycode.Key.new(:page_down),
      #
      k033: AFK.Keycode.Key.new(:caps_lock),
      k034: AFK.Keycode.Key.new(:a),
      k035: AFK.Keycode.Key.new(:s),
      k036: AFK.Keycode.Key.new(:d),
      k037: AFK.Keycode.Key.new(:f),
      k038: AFK.Keycode.Key.new(:g),
      k039: AFK.Keycode.Key.new(:h),
      k040: AFK.Keycode.Key.new(:j),
      k041: AFK.Keycode.Key.new(:k),
      k042: AFK.Keycode.Key.new(:l),
      k043: AFK.Keycode.Key.new(:semicolon),
      k044: AFK.Keycode.Key.new(:single_quote),
      k045: AFK.Keycode.Key.new(:enter),
      #
      k046: AFK.Keycode.Modifier.new(:left_shift),
      k047: AFK.Keycode.Key.new(:z),
      k048: AFK.Keycode.Key.new(:x),
      k049: AFK.Keycode.Key.new(:c),
      k050: AFK.Keycode.Key.new(:v),
      k051: AFK.Keycode.Key.new(:b),
      k052: AFK.Keycode.Key.new(:n),
      k053: AFK.Keycode.Key.new(:m),
      k054: AFK.Keycode.Key.new(:comma),
      k055: AFK.Keycode.Key.new(:period),
      k056: AFK.Keycode.Key.new(:slash),
      k057: AFK.Keycode.Modifier.new(:right_shift),
      k058: AFK.Keycode.Key.new(:up),
      #
      k059: AFK.Keycode.Modifier.new(:left_control),
      k060: AFK.Keycode.Modifier.new(:left_super),
      k061: AFK.Keycode.Modifier.new(:left_alt),
      k062: AFK.Keycode.Key.new(:space),
      k063: AFK.Keycode.Modifier.new(:right_alt),
      k064: AFK.Keycode.Layer.new(:hold, 1),
      k065: AFK.Keycode.Modifier.new(:right_control),
      k066: AFK.Keycode.Key.new(:left),
      k067: AFK.Keycode.Key.new(:down),
      k068: AFK.Keycode.Key.new(:right)
    },
    # Layer 0:
    %{
      k001: AFK.Keycode.Key.new(:grave),
      k031: AFK.Keycode.Key.new(:delete)
    }
  ]

  # Client

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Server

  @impl true
  def init([]) do
    hid = File.open!(@hid_device, [:write])

    {:ok, keyboard_state} =
      AFK.State.start_link(
        keymap: @keymap,
        event_receiver: self(),
        hid_report_mod: AFK.HIDReport.SixKeyRollover
      )

    state = %{
      buffer: [],
      held_keys: [],
      matrix_config: init_matrix_config(),
      timer: nil,
      keyboard_state: keyboard_state,
      hid: hid
    }

    send(self(), :scan)

    {:ok, state}
  end

  defp init_matrix_config do
    # transpose matrix, because we need to scan by column, not by row
    matrix_layout =
      @matrix_layout
      |> Enum.zip()
      |> Enum.map(&Tuple.to_list/1)

    # open the pins
    row_pins = @row_pins |> Enum.map(&open_input_pin!/1)
    col_pins = @col_pins |> Enum.map(&open_output_pin!/1)

    # zip the open pin resources into the matrix structure
    Enum.zip(
      col_pins,
      Enum.map(matrix_layout, fn col ->
        Enum.zip(row_pins, col)
      end)
    )
  end

  defp open_input_pin!(pin_number) do
    {:ok, ref} = GPIO.open(pin_number, :input)
    ref
  end

  defp open_output_pin!(pin_number) do
    {:ok, ref} = GPIO.open(pin_number, :output, initial_value: 0)
    ref
  end

  @impl GenServer
  def handle_info({:hid_report, hid_report}, state) do
    IO.binwrite(state.hid, hid_report)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state.buffer
    |> Enum.reverse()
    |> Utils.dedupe_events()
    |> Enum.each(fn
      {:pressed, key} ->
        AFK.State.press_key(state.keyboard_state, key)

      {:released, key} ->
        AFK.State.release_key(state.keyboard_state, key)
    end)

    {:noreply, %{state | buffer: [], timer: nil}}
  end

  @impl true
  def handle_info(:scan, state) do
    keys = scan(state.matrix_config)

    released = state.held_keys -- keys
    pressed = keys -- state.held_keys

    buffer = Enum.reduce(released, state.buffer, fn key, acc -> [{:released, key} | acc] end)
    buffer = Enum.reduce(pressed, buffer, fn key, acc -> [{:pressed, key} | acc] end)

    state =
      if buffer != state.buffer do
        set_debounce_timer(state)
      else
        state
      end

    Process.send_after(self(), :scan, 2)

    {:noreply, %{state | held_keys: keys, buffer: buffer}}
  end

  defp scan(matrix_config) do
    Enum.reduce(matrix_config, [], fn {col_pin, rows}, acc ->
      with_pin_high(col_pin, fn ->
        Enum.reduce(rows, acc, fn {row_pin, key_id}, acc ->
          case {key_id, pin_high?(row_pin)} do
            {key_id, true} when key_id != :none -> [key_id | acc]
            _else -> acc
          end
        end)
      end)
    end)
  end

  defp with_pin_high(pin, fun) do
    :ok = GPIO.write(pin, 1)
    response = fun.()
    :ok = GPIO.write(pin, 0)
    response
  end

  defp pin_high?(pin) do
    GPIO.read(pin) == 1
  end

  defp set_debounce_timer(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, @debounce_window)}
  end

  defp set_debounce_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    set_debounce_timer(%{state | timer: nil})
  end
end
