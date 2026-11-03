document.querySelectorAll('[data-copy-target]').forEach((button) => {
  const target = document.getElementById(button.dataset.copyTarget);
  const status = button.closest('.faq-answer')?.querySelector('.copy-status');
  if (!target || !status) return;

  let resetTimer;
  button.addEventListener('click', async () => {
    clearTimeout(resetTimer);
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      status.textContent = '已复制命令';
      button.querySelector('span').textContent = '已复制';
    } catch {
      status.textContent = '复制失败，请手动选择并复制命令。';
    }
    resetTimer = setTimeout(() => {
      status.textContent = '';
      button.querySelector('span').textContent = '复制';
    }, 3000);
  });
});
