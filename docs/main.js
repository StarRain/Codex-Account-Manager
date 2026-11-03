const copyMessages = document.documentElement.lang.toLowerCase().startsWith('en')
  ? { copied: 'Command copied', button: 'Copied', fallback: 'Copy failed. Please select and copy the command manually.', reset: 'Copy' }
  : { copied: '已复制命令', button: '已复制', fallback: '复制失败，请手动选择并复制命令。', reset: '复制' };

document.querySelectorAll('[data-copy-target]').forEach((button) => {
  const target = document.getElementById(button.dataset.copyTarget);
  const status = button.closest('.faq-answer')?.querySelector('.copy-status');
  if (!target || !status) return;

  let resetTimer;
  button.addEventListener('click', async () => {
    clearTimeout(resetTimer);
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      status.textContent = copyMessages.copied;
      button.querySelector('span').textContent = copyMessages.button;
    } catch {
      status.textContent = copyMessages.fallback;
    }
    resetTimer = setTimeout(() => {
      status.textContent = '';
      button.querySelector('span').textContent = copyMessages.reset;
    }, 3000);
  });
});
