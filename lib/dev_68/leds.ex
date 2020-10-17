defmodule Dev68.LEDs do
  use GenServer

  alias Circuits.GPIO
  alias RGBMatrix.Engine

  defmodule State do
    @moduledoc false
    defstruct [:ic1, :ic2, :iicrst, :sdb, :paint_fn]
  end

  # P9_11, gpio 30
  @iicrst_pin 30

  # P9_13 lo, gpio 31
  @sdb_pin 31

  # The LED matrix circuit layout on the dev-68.
  # Each atom represents 3 LEDs, unless specified by a {:pad, n} tuple.
  @matrix_a [
    [:l001, :l017, :l033, :l046, :l059, {:pad, 1}],
    [:l002, :l018, :l034, :l047, :l060, {:pad, 1}],
    [:l003, :l019, :l035, :l048, :l061, {:pad, 1}],
    [:l004, :l020, :l036, :l049, :none, {:pad, 1}],
    [:l005, :l021, :l037, :l050, :none, {:pad, 1}],
    [:l006, :l022, :l038, :l051, :l062, {:pad, 1}],
    [:l007, :l023, :l039, :l052, :none, {:pad, 1}],
    [:l008, :l024, :l040, :l053, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}]
  ]

  @matrix_b [
    [:l009, :l025, :l041, :l054, :none, {:pad, 1}],
    [:l010, :l026, :l042, :l055, :l063, {:pad, 1}],
    [:l011, :l027, :l043, :l056, :l064, {:pad, 1}],
    [:l012, :l028, :l044, :none, :l065, {:pad, 1}],
    [:l013, :l029, :none, :none, :none, {:pad, 1}],
    [:l014, :l030, :l045, :l057, :l066, {:pad, 1}],
    [:l015, :l031, :none, :l058, :l067, {:pad, 1}],
    [:l016, :l032, :none, :none, :l068, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}],
    [:none, :none, :none, :none, :none, {:pad, 1}]
  ]

  @bus_name "i2c-1"
  @ic1_addr 0x50
  @ic2_addr 0x53

  # Client

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def paint(frame) do
    GenServer.cast(__MODULE__, {:paint, frame})
  end

  # Server

  @impl GenServer
  def init([]) do
    # TODO: remove me: this should be in some "Xebow"-like application
    layout = Dev68.Layout.layout
    leds = KeyboardLayout.leds(layout)
    animation = RGBMatrix.Animation.new(RGBMatrix.Animation.SolidReactive, leds)
    RGBMatrix.Engine.set_animation(animation)
    # TODO: end remove me

    # start iicrst (hardware reset) lo and sdb (hardware shutdown) lo
    {:ok, iicrst} = GPIO.open(@iicrst_pin, :output, initial_value: 0)
    {:ok, sdb} = GPIO.open(@sdb_pin, :output, initial_value: 0)

    # start the drivers
    ic1 =
      @bus_name
      |> IS31FL3733.open(@ic1_addr)
      |> IS31FL3733.set_global_current_control(0x3C)
      |> IS31FL3733.set_swy_pull_up_resistor(:"32k")
      |> IS31FL3733.set_csx_pull_down_resistor(:"32k")
      |> IS31FL3733.set_led_on_off(0x00, led_on_off_data(@matrix_a))
      |> IS31FL3733.disable_software_shutdown()

    ic2 =
      @bus_name
      |> IS31FL3733.open(@ic2_addr)
      |> IS31FL3733.set_global_current_control(0x3C)
      |> IS31FL3733.set_swy_pull_up_resistor(:"32k")
      |> IS31FL3733.set_csx_pull_down_resistor(:"32k")
      |> IS31FL3733.set_led_on_off(0x00, led_on_off_data(@matrix_b))
      |> IS31FL3733.disable_software_shutdown()

    # turn off hardware shutdown
    :ok = GPIO.write(sdb, 1)

    # write dummy data to PWM register to flip ICs onto the PWM page
    ic1 = IS31FL3733.set_led_pwm(ic1, 0x00, <<0>>)
    ic2 = IS31FL3733.set_led_pwm(ic2, 0x00, <<0>>)

    paint_fn = register_with_engine!(ic1, ic2)

    state = %State{
      ic1: ic1,
      ic2: ic2,
      iicrst: iicrst,
      sdb: sdb,
      paint_fn: paint_fn
    }

    {:ok, state}
  end

  defp register_with_engine!(ic1, ic2) do
    pid = self()

    {:ok, paint_fn, _frame} =
      Engine.register_paintable(fn frame ->
        if Process.alive?(pid) do
          paint(ic1, ic2, frame)
          :ok
        else
          :unregister
        end
      end)

    paint_fn
  end

  defp paint(ic1, ic2, frame) do
    matrix_a_pwm_data = led_pwm_data_from_frame(@matrix_a, frame)
    matrix_b_pwm_data = led_pwm_data_from_frame(@matrix_b, frame)

    # ic1 and ic2 were captured in a closure and are not coming from the current
    # state. They should already be flipped onto the PWM page, so these calls
    # should not cause unnecessary page switching
    _ic1 = IS31FL3733.set_led_pwm(ic1, 0x00, matrix_a_pwm_data)
    _ic2 = IS31FL3733.set_led_pwm(ic2, 0x00, matrix_b_pwm_data)
  end

  @impl GenServer
  def terminate(_reason, state) do
    IS31FL3733.close(state.ic1)
    IS31FL3733.close(state.ic2)
    GPIO.write(state.sdb, 0)
    GPIO.write(state.iicrst, 1)

    Engine.unregister_paintable(state.paint_fn)
  end

  def led_on_off_data(matrix) do
    matrix
    |> Enum.flat_map(fn row ->
      Enum.flat_map(row, fn led ->
        case led do
          :none -> [false, false, false]
          {:pad, 1} -> [false]
          _else -> [true, true, true]
        end
      end)
    end)
    |> Enum.chunk_every(8)
    |> Enum.into(<<>>, fn chunk ->
      for led <- Enum.reverse(chunk),
          do: if(led, do: <<1::1>>, else: <<0::1>>),
          into: <<>>
    end)
  end

  def led_pwm_data_from_frame(matrix, frame) do
    for row <- matrix,
        led <- row,
        do:
          (case led do
             :none -> <<0::24>>
             {:pad, 1} -> <<0::size(8)>>
             led -> frame |> Map.fetch!(led) |> color_to_bytes()
           end),
        into: <<>>
  end

  defp color_to_bytes(color) do
    rgb = Chameleon.convert(color, Chameleon.Color.RGB)
    <<rgb.b, rgb.r, rgb.g>>
  end

  @impl true
  def handle_cast({:paint, frame}, state) do
    paint(state.ic1, state.ic2, frame)

    {:noreply, state}
  end
end
