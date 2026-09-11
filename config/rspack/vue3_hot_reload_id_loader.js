// OC Change: vue-loader derives its hot-reload id from the file path alone in
// development (`hash(shortFilePath)`, lib/index.js), and `?vue3` is not part of
// the path. So the clean and infected copies of one component share an id, and
// because `vue-hot-reload-api` is bypassed by the infection scanner they also
// share one record map. The copy that loads second takes the `else` branch of
// vue-loader's generated block and calls `api.reload(id, component.options)`,
// overwriting the first copy's options — which lands a compat-built child (e.g.
// bootstrap-vue's `BModal`) on a Vue 2 constructor. Vue 2 then reads
// `sealedOptions`, which only its own `extend` sets, and throws inside a
// `nextTick` flush; `resetSchedulerState()` never runs and the page's Vue 2
// scheduler is wedged for good.
//
// Giving the infected copy its own id keeps hot reload working for both.
const HOT_RELOAD_CALL = /(api\.(?:isRecorded|createRecord|reload|rerender)\(')([^']+)(')/g;

module.exports = function vue3HotReloadIdLoader(source) {
  return source.replace(HOT_RELOAD_CALL, (match) => match.replace(/'$/, "-vue3'"));
};

module.exports.HOT_RELOAD_ID_LOADER_PATH = __filename;
