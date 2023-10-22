defmodule Entrace do
  @moduledoc """
  Base module for starting a GenServer that performs tracing.

  Typically you would rather add a module to your project that uses the `Entrace.Tracer`.

  ```elixir
  defmodule MyApp.Tracer do
    use Entrace.Tracer
  end
  ```

  And in your application.ex list och children to supervise add:application

  ```
  MyApp.Tracer
  ```

  It will run as locally registered on it's module name (in this case `MyApp.Tracer`).

  It is not useful to run multiple Tracer instances as the Erlang tracing facility has a limit on the numer of traces.

  """
  use GenServer
  import Ex2ms
  require Logger
  alias Entrace.Trace
  alias Entrace.TracePatterns

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @default_limit 100
  def trace(tracer, mfa, callback, opts \\ [])

  def trace(tracer, {m, f, a} = mfa, callback, opts)
      when is_atom(m) and is_atom(f) and (is_integer(a) or a == :_) and is_function(callback) do
    limit = opts[:limit] || @default_limit
    do_trace(tracer, mfa, callback, limit)
  end

  def trace(tracer, {m, f, a} = mfa, {m2, f2, 1} = callback_mfa, opts)
      when is_atom(m) and is_atom(f) and (is_integer(a) or a == :_) and is_atom(m2) and
             is_atom(f2) do
    limit = opts[:limit] || @default_limit
    do_trace(tracer, mfa, callback_mfa, limit)
  end

  def trace(tracer, {m, f, a} = mfa, recipient_pid, opts)
      when is_atom(m) and is_atom(f) and (is_integer(a) or a == :_) and is_pid(recipient_pid) do
    limit = opts[:limit] || @default_limit
    do_trace(tracer, mfa, recipient_pid, limit)
  end

  def stop(tracer, {m, f, a} = mfa)
      when is_atom(m) and is_atom(f) and (is_integer(a) or a == :_) do
    do_stop(tracer, mfa)
  end

  def exit(pid) do
    Process.exit(pid, :user_halt)
  end

  def list_traces(tracer) do
    GenServer.call(tracer, :list_traces)
  end

  defp do_trace(tracer, mfa, transmission, limit) do
    GenServer.call(tracer, {:set_trace_pattern, mfa, transmission, limit})
  end

  defp do_stop(tracer, mfa) do
    GenServer.call(tracer, {:unset_trace_pattern, mfa})
  end

  @impl GenServer
  def init(_) do
    Logger.debug("Starting Entrace GenServer...")
    mon_ref = Process.monitor(self())

    state = %{
      trace_patterns: TracePatterns.new(),
      unmatched_traces: %{},
      matched_traces: [],
      ref: mon_ref
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:trace_ts, from_pid, :call, mfarguments, ts}, state) do
    Logger.debug("Receiving call event from #{inspect(from_pid)} for #{inspect(mfarguments)}.")
    datetime = ts_to_dt!(ts)
    id = System.unique_integer([:positive, :monotonic])

    trace = Trace.new(id, mfarguments, from_pid, datetime)
    mfarity = call_mfa_to_key(mfarguments)
    pattern = TracePatterns.covered_by(state.trace_patterns, mfarity) || mfarity
    trace_pattern = Map.get(state.trace_patterns, pattern)

    trace_patterns =
      if trace_pattern do
        transmit(trace_pattern.transmission, trace)

        if TracePatterns.within_limit?(state.trace_patterns, pattern) do
          TracePatterns.increment(state.trace_patterns, pattern)
        else
          clear_pattern(pattern)

          TracePatterns.remove(state.trace_patterns, pattern)
        end
      else
        state.trace_patterns
      end

    key = {from_pid, mfarity}
    unmatched = Map.put(state.unmatched_traces, key, trace)

    {:noreply, %{state | unmatched_traces: unmatched, trace_patterns: trace_patterns}}
  end

  def handle_info({:trace_ts, from_pid, :return_from, mfa, return, ts}, state) do
    Logger.debug("Receiving return_from event from #{inspect(from_pid)} for #{inspect(mfa)}.")
    datetime = ts_to_dt!(ts)
    key = {from_pid, mfa}
    pattern = TracePatterns.covered_by(state.trace_patterns, mfa) || mfa
    trace_pattern = Map.get(state.trace_patterns, pattern)

    {unmatched, matched} =
      case Map.pop(state.unmatched_traces, key) do
        {nil, unmatched} ->
          Logger.error("Got return trace but found no unmatched call.")
          {unmatched, state.matched_traces}

        {trace, unmatched} ->
          trace = Trace.with_return(trace, mfa, from_pid, datetime, return)

          if trace_pattern do
            transmit(trace_pattern.transmission, trace)
          end

          {unmatched, [trace | state.matched_traces]}
      end

    trace_patterns =
      if trace_pattern do
        if TracePatterns.within_limit?(state.trace_patterns, pattern) do
          TracePatterns.increment(state.trace_patterns, pattern)
        else
          clear_pattern(pattern)
          TracePatterns.remove(state.trace_patterns, pattern)
        end
      else
        state.trace_patterns
      end

    {:noreply,
     %{
       state
       | matched_traces: matched,
         unmatched_traces: unmatched,
         trace_patterns: trace_patterns
     }}
  end

  def handle_info({:DOWN, ref, :process, _object, _reason}, %{ref: ref} = state) do
    Logger.debug("shutting down and disabling traces")
    off(self())
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_call({:set_trace_pattern, {:_, :_, :_}, _, _}, _from, state) do
    {:reply, {:error, :full_wildcard_rejected}, state}
  end

  def handle_call({:set_trace_pattern, mfa, transmission, limit}, _from, state)
      when is_pid(transmission) or is_function(transmission) or is_tuple(transmission) do
    if TracePatterns.count(state.trace_patterns) == 0 do
      Logger.debug("Enabling tracing...")
      processes = on(self())
      Logger.debug("Matched #{processes} existing processes")
    end

    trace_pattern = %{mfa: mfa, msg_count: 0, limit: limit, transmission: transmission}

    {result, trace_patterns} =
      if TracePatterns.exists?(state.trace_patterns, mfa) do
        Logger.debug("Clearing existing trace pattern: #{inspect(mfa)}")
        clear_pattern(mfa)
        Logger.debug("Resetting trace pattern: #{inspect(mfa)}")
        functions = set_pattern(mfa)
        Logger.debug("Matched #{functions} functions")
        tps = TracePatterns.add(state.trace_patterns, mfa, trace_pattern)
        {{:ok, {:reset_existing, functions}}, tps}
      else
        case TracePatterns.covered_by(state.trace_patterns, mfa) do
          nil ->
            Logger.debug("Setting trace pattern: #{inspect(mfa)}")
            functions = set_pattern(mfa)
            Logger.debug("Matched #{functions} functions")
            tps = TracePatterns.add(state.trace_patterns, mfa, trace_pattern)
            {{:ok, {:set, functions}}, tps}

          covering ->
            Logger.debug(
              "Trace pattern #{inspect(mfa)} is already covered by #{inspect(covering)}. Not setting."
            )

            {{:error, {:covered_already, mfa}}, state.trace_patterns}
        end
      end

    {:reply, result, %{state | trace_patterns: trace_patterns}}
  end

  def handle_call({:unset_trace_pattern, mfa}, _from, state) do
    trace_patterns = TracePatterns.remove(state.trace_patterns, mfa)

    if Enum.count(trace_patterns) == 0 do
      clear_pattern(mfa)
    end

    {:reply, :ok, %{state | trace_patterns: trace_patterns}}
  end

  def handle_call(:list_traces, _from, state) do
    {:reply, Map.keys(state.trace_patterns), state}
  end

  defp transmit({module, function, 1} = _mfa, trace) do
    apply(module, function, [trace])
  end

  defp transmit(callback, trace) when is_function(callback) do
    callback.(trace)
  end

  defp transmit(pid, trace) when is_pid(pid) do
    send(pid, {:trace, trace})
  end

  defp on(pid) do
    :erlang.trace(:all, true, [:call, :timestamp, {:tracer, pid}])
    # :erlang.trace(:all, true, [:call, {:tracer, pid}])
  end

  defp off(pid) do
    :erlang.trace(:all, false, [:call, :timestamp, {:tracer, pid}])
    # :erlang.trace(:all, false, [:call, {:tracer, pid}])
  end

  defp set_pattern(mfa) do
    # :erlang.trace_pattern(mfa, [{'_', [], [{:return_trace}]}], [:local])
    :erlang.trace_pattern(mfa, match_spec(), [:local])
  end

  defp clear_pattern(mfa) do
    Logger.debug("Clearing pattern #{inspect(mfa)}")
    :erlang.trace_pattern(mfa, false, [:local])
  end

  defp match_spec() do
    fun do
      _ ->
        return_trace()
        exception_trace()
    end
  end

  defp ts_to_dt!({megaseconds, seconds, microseconds}) do
    microseconds
    |> add(seconds_to_micro(seconds))
    |> add(megaseconds_to_micro(megaseconds))
    |> DateTime.from_unix!(:microsecond)
  end

  defp call_mfa_to_key({m, f, a}) when is_list(a) do
    {m, f, Enum.count(a)}
  end

  defp add(a, b), do: a + b
  defp seconds_to_micro(seconds), do: seconds * 1_000_000
  defp megaseconds_to_micro(megaseconds), do: megaseconds * 1_000_000_000_000
end
