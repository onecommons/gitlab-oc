// Save changes only applies to the confidential checkbox, so it shows only
// while that differs from what is saved.
export default function initWorkItemsSyncSettings() {
  const checkbox = document.querySelector('.js-work-items-sync-confidential');
  const save = document.querySelector('.js-work-items-sync-save');
  if (!checkbox || !save) return;

  const saved = checkbox.checked;
  checkbox.addEventListener('change', () => {
    save.classList.toggle('gl-hidden', checkbox.checked === saved);
  });
}
