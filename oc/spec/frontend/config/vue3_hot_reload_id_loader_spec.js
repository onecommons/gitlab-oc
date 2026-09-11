import vue3HotReloadIdLoader from '../../../../config/rspack/vue3_hot_reload_id_loader';

// vue-loader emits this block verbatim for a .vue main request in development,
// with the id hashed from the file path alone — so a component's clean and
// `?vue3` copies arrive here carrying the same one.
const hotReloadBlock = (id) => `
if (module.hot) {
  var api = require("vue-hot-reload-api")
  api.install(require('vue'))
  if (api.compatible) {
    module.hot.accept()
    if (!api.isRecorded('${id}')) {
      api.createRecord('${id}', component.options)
    } else {
      api.reload('${id}', component.options)
    }
    module.hot.accept("./modal.vue?vue&type=template&id=${id}", function () {
      api.rerender('${id}', { render: render, staticRenderFns: staticRenderFns })
    })
  }
}`;

describe('vue3HotReloadIdLoader', () => {
  it('gives the infected copy an id of its own', () => {
    const transformed = vue3HotReloadIdLoader(hotReloadBlock('932f7b4a'));

    // The point of the loader: the two copies must not share a record, because
    // the second to load would otherwise `api.reload` over the first's options.
    expect(transformed).not.toContain("'932f7b4a'");
    expect(transformed).toContain("'932f7b4a-vue3'");
  });

  it.each(['isRecorded', 'createRecord', 'reload', 'rerender'])(
    'rewrites the id passed to api.%s',
    (method) => {
      expect(vue3HotReloadIdLoader(hotReloadBlock('932f7b4a'))).toContain(
        `api.${method}('932f7b4a-vue3'`,
      );
    },
  );

  it('leaves everything that is not a hot-reload id alone', () => {
    const source = `
      const id = '932f7b4a'
      api.install(require('vue'))
      module.hot.accept("./modal.vue?vue&type=template&id=932f7b4a", cb)
    `;

    expect(vue3HotReloadIdLoader(source)).toBe(source);
  });

  it('passes through a module with no hot-reload block', () => {
    const source = 'export default { name: "GlModal" }';

    expect(vue3HotReloadIdLoader(source)).toBe(source);
  });
});
