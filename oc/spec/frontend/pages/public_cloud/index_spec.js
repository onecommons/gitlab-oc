jest.mock('oc/public_cloud', () => jest.fn());

describe('public-cloud page entry point', () => {
  // The entry point runs its work on import, so each example has to load it
  // afresh after jest.resetModules rather than hold a top-level binding.
  /* eslint-disable global-require */
  const loadEntryPoint = () => require('oc/pages/public_cloud');
  const publicCloudInitializer = () => require('oc/public_cloud');
  /* eslint-enable global-require */

  beforeEach(() => {
    jest.resetModules();
    document.body.innerHTML = '';
    publicCloudInitializer().mockClear();
  });

  it('mounts the OC public-cloud application only when its mount point exists', () => {
    document.body.innerHTML = '<div id="public-cloud-layout"></div>';

    loadEntryPoint();

    expect(publicCloudInitializer()).toHaveBeenCalledTimes(1);
  });

  it('does not initialize the application on unrelated pages', () => {
    loadEntryPoint();

    expect(publicCloudInitializer()).not.toHaveBeenCalled();
  });
});
