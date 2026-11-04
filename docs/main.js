const isEnglish = document.documentElement.lang.toLowerCase().startsWith('en');
const copyMessages = isEnglish
  ? { copied: 'Command copied', button: 'Copied', fallback: 'Copy failed. Please select and copy the command manually.', reset: 'Copy' }
  : { copied: '已复制命令', button: '已复制', fallback: '复制失败，请手动选择并复制命令。', reset: '复制' };

// Native links and details remain usable when JavaScript is unavailable.
document.querySelectorAll('[data-copy-target]').forEach((button) => {
  const target = document.getElementById(button.dataset.copyTarget);
  const status = button.closest('.faq-answer')?.querySelector('.copy-status');
  if (!target || !status) return;

  const label = button.querySelector('span');
  const icon = button.querySelector('use');
  let resetTimer;
  let request = 0;
  button.addEventListener('click', async () => {
    const currentRequest = ++request;
    clearTimeout(resetTimer);
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      if (currentRequest !== request) return;
      status.textContent = copyMessages.copied;
      label.textContent = copyMessages.button;
      icon?.setAttribute('href', '#i-check');
    } catch {
      if (currentRequest !== request) return;
      status.textContent = copyMessages.fallback;
      label.textContent = copyMessages.reset;
      icon?.setAttribute('href', '#i-copy');
    }
    resetTimer = setTimeout(() => {
      status.textContent = '';
      label.textContent = copyMessages.reset;
      icon?.setAttribute('href', '#i-copy');
    }, 3000);
  });
});

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');
const revealElements = [...document.querySelectorAll('[data-reveal]')];
let revealObserver;

if ('IntersectionObserver' in window && !reducedMotion.matches) {
  revealObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.remove('reveal-pending');
      entry.target.classList.add('reveal-visible');
      revealObserver.unobserve(entry.target);
    }
  }, { threshold: 0.08, rootMargin: '0px 0px -24px 0px' });

  for (const element of revealElements) {
    if (element.getBoundingClientRect().top < window.innerHeight) continue;
    element.classList.add('reveal-pending');
    revealObserver.observe(element);
  }
}

const header = document.querySelector('.site-header');
const navSections = [...document.querySelectorAll('.nav-links a[href^="#"]')]
  .map((link) => ({ link, section: document.querySelector(link.getAttribute('href')) }))
  .filter(({ section }) => section);
let scrollFrame = 0;
function updateScrollState() {
  scrollFrame = 0;
  const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
  const progress = maxScroll > 0 ? Math.min(1, Math.max(0, window.scrollY / maxScroll)) : 0;
  header?.style.setProperty('--read-progress', progress.toFixed(4));
  header?.classList.toggle('is-scrolled', window.scrollY > 16);
  let active;
  for (const item of navSections) {
    const bounds = item.section.getBoundingClientRect();
    if (bounds.top < window.innerHeight * 0.45 && bounds.bottom > 100) active = item.link;
  }
  for (const { link } of navSections) {
    if (link === active) link.setAttribute('aria-current', 'location');
    else link.removeAttribute('aria-current');
  }
}
function scheduleScrollUpdate() {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(updateScrollState);
}
window.addEventListener('scroll', scheduleScrollUpdate, { passive: true });
window.addEventListener('resize', scheduleScrollUpdate, { passive: true });
updateScrollState();

const hero = document.querySelector('.hero-shell');
let heroVisible = true;
function updateAmbientMotion() {
  hero?.classList.toggle('motion-paused', !heroVisible || document.hidden || reducedMotion.matches);
}
if (hero && 'IntersectionObserver' in window) {
  const heroObserver = new IntersectionObserver(([entry]) => {
    heroVisible = entry.isIntersecting;
    updateAmbientMotion();
  });
  heroObserver.observe(hero);
}
document.addEventListener('visibilitychange', updateAmbientMotion);
updateAmbientMotion();

// Pointer effects are event-driven, with no animation loop while idle.
const pointerTargets = [...document.querySelectorAll('[data-spotlight], .screenshot-trigger')];
const pointerResets = [];
for (const element of pointerTargets) {
  let frame = 0;
  let pointer;
  const isScreenshot = element.matches('.screenshot-trigger');
  const reset = () => {
    cancelAnimationFrame(frame);
    frame = 0;
    pointer = undefined;
    ['--pointer-x', '--pointer-y', '--tilt-x', '--tilt-y'].forEach((property) => element.style.removeProperty(property));
  };
  pointerResets.push(reset);
  element.addEventListener('pointermove', (event) => {
    if (reducedMotion.matches || !finePointer.matches || event.pointerType === 'touch') return;
    pointer = { x: event.clientX, y: event.clientY };
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      if (!pointer) return;
      const bounds = element.getBoundingClientRect();
      const x = Math.max(0, Math.min(1, (pointer.x - bounds.left) / bounds.width));
      const y = Math.max(0, Math.min(1, (pointer.y - bounds.top) / bounds.height));
      if (isScreenshot) {
        element.style.setProperty('--tilt-x', `${(1 - y * 2).toFixed(2)}deg`);
        element.style.setProperty('--tilt-y', `${((x - 0.5) * 3).toFixed(2)}deg`);
      } else {
        element.style.setProperty('--pointer-x', `${(x * 100).toFixed(1)}%`);
        element.style.setProperty('--pointer-y', `${(y * 100).toFixed(1)}%`);
      }
    });
  });
  element.addEventListener('pointerleave', reset);
  element.addEventListener('pointercancel', reset);
}
function resetMotionPreferences() {
  pointerResets.forEach((reset) => reset());
  if (reducedMotion.matches) {
    revealObserver?.disconnect();
    revealElements.forEach((element) => element.classList.remove('reveal-pending', 'reveal-visible'));
  }
  updateAmbientMotion();
}
reducedMotion.addEventListener('change', resetMotionPreferences);
finePointer.addEventListener('change', resetMotionPreferences);

const preview = document.querySelector('.preview-dialog');
const previewTrigger = document.querySelector('[data-preview-open]');
if (preview && previewTrigger && typeof preview.showModal === 'function') {
  previewTrigger.addEventListener('click', (event) => {
    event.preventDefault();
    if (preview.open) return;
    preview.showModal();
    document.body.classList.add('preview-open');
  });
  preview.querySelector('.preview-close')?.addEventListener('click', () => preview.close());
  preview.addEventListener('click', (event) => {
    if (event.target !== preview) return;
    const bounds = preview.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) preview.close();
  });
  preview.addEventListener('close', () => {
    document.body.classList.remove('preview-open');
    previewTrigger.focus({ preventScroll: true });
  });
}
