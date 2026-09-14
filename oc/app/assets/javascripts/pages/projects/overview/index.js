import initProjectOverview from 'oc/project_overview';
import initUnfurlBadgeUrlBuilder from 'oc/pages/projects/edit/uf_badge';
import UserCallout from '~/user_callout';

new UserCallout({ className: 'js-uf-welcome-banner' }); // eslint-disable-line no-new

initProjectOverview();

// The badge settings form is rendered server-side and handed to oc-pages,
// which paints it into the share modal. Binding here rather than on the edit
// page, which is where 15.11 imported it and is not where the form appears.
initUnfurlBadgeUrlBuilder();
