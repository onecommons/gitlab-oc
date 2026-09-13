<script>
import { normalizeRender } from '~/lib/utils/vue3compat/normalize_render';

export default normalizeRender({
  name: 'LineNumber',
  functional: true,
  props: {
    lineNumber: {
      type: Number,
      required: true,
    },
    path: {
      type: String,
      required: true,
    },
  },
  render(h, { props }) {
    // OC Change - hash-only href: the log is embedded in the dashboard's
    // console, where a full path would navigate away from it
    const { lineNumber } = props;

    const lineId = `L${lineNumber}`;
    const lineHref = `#${lineId}`;

    return h(
      'a',
      {
        class: 'job-log-line-number',
        attrs: {
          id: lineId,
          href: lineHref,
        },
      },
      lineNumber,
    );
  },
});
</script>
