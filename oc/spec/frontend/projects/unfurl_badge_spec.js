import { resetHTMLFixture, setHTMLFixture } from 'helpers/fixtures';
import initUnfurlBadgeUrlBuilder from 'oc/pages/projects/edit/uf_badge';

describe('Unfurl deploy-badge URL builder', () => {
  const badgeUrl = 'http://gitlab.test/group/blueprint/-/deploybutton.svg';

  beforeEach(() => {
    setHTMLFixture(`
      <select id="uf-badge-type"><option value="default">Default</option><option value="white">White</option></select>
      <input id="uf-badge-cloud" type="checkbox" />
      <input id="uf-badge-count" type="checkbox" />
      <input id="js-uf-badge-link" value="${badgeUrl}" />
      <input id="js-uf-badge-embed" />
      <a id="js-uf-badge-img"><img src="${badgeUrl}" /></a>
    `);

    initUnfurlBadgeUrlBuilder();
  });

  afterEach(() => {
    resetHTMLFixture();
  });

  it('updates the direct link, preview, and embeddable link with selected display options', () => {
    const type = document.querySelector('#uf-badge-type');
    const cloud = document.querySelector('#uf-badge-cloud');
    const count = document.querySelector('#uf-badge-count');

    type.value = 'white';
    type.dispatchEvent(new Event('change'));
    cloud.checked = true;
    cloud.dispatchEvent(new Event('change'));
    count.checked = true;
    count.dispatchEvent(new Event('change'));

    const directLink = new URL(document.querySelector('#js-uf-badge-link').value);
    const previewLink = new URL(document.querySelector('#js-uf-badge-img img').src);
    const embed = document.querySelector('#js-uf-badge-embed').value;

    expect(directLink.searchParams).toEqual(previewLink.searchParams);
    expect(directLink.searchParams.get('type')).toBe('white');
    expect(directLink.searchParams.get('cloud')).toBe('true');
    expect(directLink.searchParams.get('count')).toBe('true');
    expect(embed).toContain('<a href="http://gitlab.test/group/blueprint">');
    expect(embed).toContain(`src="${directLink.toString()}"`);
  });
});
