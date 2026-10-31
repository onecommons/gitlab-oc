import initPublicCloud from 'oc/public_cloud';
import { createAlert } from '~/alert';
import { __ } from '~/locale';

if (document.getElementById('public-cloud-layout')) {
  initPublicCloud().catch((error) => {
    createAlert({
      message: __(
        'The cloud catalog could not be loaded. The Unfurl server may be unavailable; try again later.',
      ),
      captureError: true,
      error,
    });
  });
}
