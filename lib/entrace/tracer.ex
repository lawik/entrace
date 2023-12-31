defmodule Entrace.Tracer do
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      def child_spec(opts) do
        opts = Keyword.put(opts, :name, __MODULE__)

        %{
          id: Entrace,
          start: {Entrace, :start_link, [opts]}
        }
      end

      def trace(pattern, transmission, opts \\ []),
        do: Entrace.trace(__MODULE__, pattern, transmission, opts)

      def trace_cluster(pattern, transmission, opts \\ []),
        do: Entrace.trace_cluster(__MODULE__, pattern, transmission, opts)

      def stop(pattern),
        do: Entrace.stop(__MODULE__, pattern)

      def list_traces, do: Entrace.list_traces(__MODULE__)
    end
  end
end
