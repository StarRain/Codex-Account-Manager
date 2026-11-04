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
const motionButton = document.querySelector('.motion-toggle');
const motionStorageKey = 'cam.website.motion';
let motionPreference = null;
try {
  const saved = localStorage.getItem(motionStorageKey);
  if (saved === 'on' || saved === 'off') motionPreference = saved;
} catch {
  // The page still works when browser storage is unavailable.
}
let motionEnabled = motionPreference ? motionPreference === 'on' : !reducedMotion.matches;

const header = document.querySelector('.site-header');
const hero = document.querySelector('.hero-shell');
const productFigure = document.querySelector('.product-figure');
const productStage = document.querySelector('.product-stage');
const revealElements = [...document.querySelectorAll('[data-reveal]')];
const scenes = [...document.querySelectorAll('[data-motion-scene]')];
const navSections = [...document.querySelectorAll('.nav-links a[href^="#"]')]
  .map((link) => ({ link, section: document.querySelector(link.getAttribute('href')) }))
  .filter(({ section }) => section);
let revealObserver;
let heroVisible = true;
let scrollFrame = 0;

function configureReveals() {
  revealObserver?.disconnect();
  revealElements.forEach((element) => element.classList.remove('reveal-pending', 'reveal-visible'));
  if (!motionEnabled || !('IntersectionObserver' in window)) return;

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

// Use the untransformed figure for progress so the animation cannot affect its own measurement.
function updateProductScene() {
  if (!productFigure || !productStage) return;
  if (!motionEnabled) {
    ['--stage-angle', '--stage-scale', '--stage-lift'].forEach((property) => productStage.style.removeProperty(property));
    return;
  }
  const viewport = window.innerHeight;
  const top = productFigure.getBoundingClientRect().top;
  const progress = Math.max(0, Math.min(1, (viewport * 0.98 - top) / (viewport * 0.72)));
  const eased = progress * progress * (3 - 2 * progress);
  const remaining = 1 - eased;
  const compact = window.innerWidth <= 640;
  productStage.style.setProperty('--stage-angle', `${(remaining * (compact ? 16 : 28)).toFixed(2)}deg`);
  productStage.style.setProperty('--stage-scale', (1 - remaining * (compact ? 0.08 : 0.12)).toFixed(4));
  productStage.style.setProperty('--stage-lift', `${(remaining * (compact ? 26 : 55)).toFixed(2)}px`);
}

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
  updateProductScene();
}
function scheduleScrollUpdate() {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(updateScrollState);
}

function updateAmbientMotion() {
  document.documentElement.classList.toggle('page-inactive', document.hidden);
  hero?.classList.toggle('motion-paused', !heroVisible || document.hidden || !motionEnabled);
}

if ('IntersectionObserver' in window) {
  const sceneObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.target === hero) heroVisible = entry.isIntersecting;
      else entry.target.classList.toggle('is-in-view', entry.isIntersecting);
    }
    updateAmbientMotion();
  }, { threshold: 0.05 });
  if (hero) sceneObserver.observe(hero);
  scenes.forEach((scene) => sceneObserver.observe(scene));
} else {
  scenes.forEach((scene) => scene.classList.add('is-in-view'));
}

// Pointer and scroll transforms live on separate elements, so they do not compete.
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
    if (!motionEnabled || !finePointer.matches || event.pointerType === 'touch') return;
    pointer = { x: event.clientX, y: event.clientY };
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      if (!pointer) return;
      const bounds = element.getBoundingClientRect();
      const x = Math.max(0, Math.min(1, (pointer.x - bounds.left) / bounds.width));
      const y = Math.max(0, Math.min(1, (pointer.y - bounds.top) / bounds.height));
      if (isScreenshot) {
        element.style.setProperty('--tilt-x', `${(2 - y * 4).toFixed(2)}deg`);
        element.style.setProperty('--tilt-y', `${((x - 0.5) * 5).toFixed(2)}deg`);
      } else {
        element.style.setProperty('--pointer-x', `${(x * 100).toFixed(1)}%`);
        element.style.setProperty('--pointer-y', `${(y * 100).toFixed(1)}%`);
      }
    });
  });
  element.addEventListener('pointerleave', reset);
  element.addEventListener('pointercancel', reset);
}

function applyMotionPreference() {
  document.documentElement.dataset.motion = motionEnabled ? 'on' : 'off';
  if (motionButton) {
    const action = isEnglish
      ? (motionEnabled ? 'Pause animations' : 'Play animations')
      : (motionEnabled ? '暂停动效' : '播放动效');
    motionButton.hidden = false;
    motionButton.setAttribute('aria-pressed', String(motionEnabled));
    motionButton.setAttribute('aria-label', action);
    motionButton.title = action;
    motionButton.querySelector('span').textContent = isEnglish
      ? (motionEnabled ? 'Motion on' : 'Motion off')
      : (motionEnabled ? '动效开' : '动效关');
    motionButton.querySelector('use').setAttribute('href', motionEnabled ? '#i-pause' : '#i-play');
  }
  pointerResets.forEach((reset) => reset());
  configureReveals();
  updateAmbientMotion();
  updateScrollState();
}

motionButton?.addEventListener('click', () => {
  motionEnabled = !motionEnabled;
  motionPreference = motionEnabled ? 'on' : 'off';
  try { localStorage.setItem(motionStorageKey, motionPreference); } catch { /* Keep the choice for this visit. */ }
  applyMotionPreference();
});
reducedMotion.addEventListener('change', () => {
  if (motionPreference !== null) return;
  motionEnabled = !reducedMotion.matches;
  applyMotionPreference();
});
finePointer.addEventListener('change', () => pointerResets.forEach((reset) => reset()));
document.addEventListener('visibilitychange', updateAmbientMotion);
window.addEventListener('scroll', scheduleScrollUpdate, { passive: true });
window.addEventListener('resize', scheduleScrollUpdate, { passive: true });
window.addEventListener('pageshow', scheduleScrollUpdate);
document.addEventListener('focusin', (event) => {
  const target = event.target.closest?.('[data-reveal]');
  if (!target) return;
  target.classList.remove('reveal-pending');
  revealObserver?.unobserve(target);
});
applyMotionPreference();

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
