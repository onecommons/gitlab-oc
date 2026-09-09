import '~/pages/registrations/new';
import { getCookie, setCookie } from '~/lib/utils/common_utils';
import { getParameterByName } from '~/lib/utils/url_utility';

// An invite link carries the code in the query string; keep it for the signup
// that follows, which may be several pages later.
const INVITE_CODE = 'invite_code';

const fromQuery = getParameterByName(INVITE_CODE);

if (fromQuery) {
  setCookie(INVITE_CODE, fromQuery);
}

const field = document.getElementById('js-oc-invite-code');
const code = fromQuery || getCookie(INVITE_CODE);

if (field && code) {
  field.value = code;
}
