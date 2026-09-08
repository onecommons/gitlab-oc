import $ from 'jquery';

let badgeType;
let badgeCloud;
let badgeCount;
let badgeImage;
let badgeLink;
let badgeEmbed;

function unfurlBadgeListener() {
  const badgeUrl = new URL(badgeImage[0].firstChild.src);
  const params = badgeUrl.searchParams;

  params.set('type', badgeType.val());
  if (badgeCloud.prop('checked')) {
    params.set('cloud', true);
  } else {
    params.delete('cloud');
  }
  if (badgeCount.prop('checked')) {
    params.set('count', true);
  } else {
    params.delete('count');
  }

  badgeLink.val(badgeUrl.toString());
  badgeImage[0].firstChild.src = badgeUrl.toString();
  // eslint-disable-next-line @gitlab/no-hardcoded-urls -- the badge route, whose prefix is the project URL
  const projectUrl = badgeUrl.toString().split('/-/deploybutton.svg')[0];
  badgeEmbed.val(
    `<a href="${projectUrl}"><img alt="Deploy with Unfurl Cloud" src="${badgeUrl.toString()}" /></a>`,
  );
}

// Wires the deploy badge builder on the share modal and the repository settings page.
export default function initUnfurlBadgeUrlBuilder() {
  badgeType = $('#uf-badge-type');
  badgeCloud = $('#uf-badge-cloud');
  badgeCount = $('#uf-badge-count');

  badgeImage = $('#js-uf-badge-img');
  badgeLink = $('#js-uf-badge-link');
  badgeEmbed = $('#js-uf-badge-embed');

  badgeType.on('change', unfurlBadgeListener);
  badgeCloud.on('change', unfurlBadgeListener);
  badgeCount.on('change', unfurlBadgeListener);
}
