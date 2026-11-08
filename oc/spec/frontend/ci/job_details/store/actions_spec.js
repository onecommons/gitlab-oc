import { setHTMLFixture, resetHTMLFixture } from 'helpers/fixtures';
import { scrollBottom } from '~/ci/job_details/store/actions';
import { scrollDown } from '~/lib/utils/scroll_utils';

jest.mock('~/lib/utils/scroll_utils');

// The dashboard embeds the job log in its own console, which scrolls itself;
// scrolling the window there would move the dashboard instead.
describe('scrollBottom in the dashboard console', () => {
  afterEach(() => {
    resetHTMLFixture();
  });

  it('leaves scrolling to the console when it is on the page', () => {
    setHTMLFixture('<div id="console-container"></div>');

    scrollBottom();

    expect(scrollDown).not.toHaveBeenCalled();
  });

  it('scrolls the window as upstream does elsewhere', () => {
    scrollBottom();

    expect(scrollDown).toHaveBeenCalled();
  });
});
