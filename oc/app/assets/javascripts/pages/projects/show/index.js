import initDashboard from 'oc_dashboard';
import '~/pages/projects/show';

// A dashboard project renders the oc-pages dashboard instead of the repository
// page; every other project keeps the CE entry imported above.
if (document.getElementById('js-table-component')) {
  initDashboard();
}
