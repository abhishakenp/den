// Plugin-only glue: builds a PluginEnv from the cordis Context. Not part of the test target.
import Darwin

extension PluginEnv {
  init(_ ctx: Context) {
    self.init(
      invoke: { s, m, a in ctx.call(s, m, a) },
      emit: { e, p in ctx.emit(e, p) },
      on: { e, h in ctx.on(e, h) },
      timer: { ms, repeats, h in ctx.timer(milliseconds: ms, repeats: repeats, h) },
      now: {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
      },
      log: { ctx.log($0) })
  }
}
