'use strict';

const selectedPages = new WeakSet();
const observedPages = new WeakSet();

async function locatorVisible(locator) {
  if (!locator) return false;
  const count = await locator.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) return true;
  }
  return false;
}

async function selectServerModeIfChooser(page, targetLocator) {
  if (selectedPages.has(page)) return false;
  if (!observedPages.has(page)) {
    observedPages.add(page);
    page.on('framenavigated', (frame) => {
      if (frame === page.mainFrame()) selectedPages.delete(page);
    });
  }

  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const chooserVisible = await page.evaluate(() => {
      const visibleSemanticText = [...document.querySelectorAll('flt-semantics')]
        .filter((element) => {
          const style = getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
        })
        .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
        .join('\n');
      const visibleText = `${document.body.innerText || ''}\n${visibleSemanticText}`;
      return visibleText.includes('Choose a workspace') &&
        visibleText.includes('Server account and sync');
    }).catch(() => false);

    if (chooserVisible) {
      const continueButtons = page.getByRole('button', { name: 'Continue', exact: true });
      const count = await continueButtons.count();
      for (let index = 0; index < count; index += 1) {
        const candidate = continueButtons.nth(index);
        if (await candidate.isVisible().catch(() => false) &&
            await candidate.isEnabled().catch(() => false)) {
          await candidate.click();
          selectedPages.add(page);
          return true;
        }
      }
    } else if (await locatorVisible(targetLocator)) {
      selectedPages.add(page);
      return false;
    } else if (!targetLocator) {
      const serverModeVisible = await page.evaluate(() => {
        const visibleSemanticText = [...document.querySelectorAll('flt-semantics')]
          .filter((element) => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' && style.visibility !== 'hidden' &&
              Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
          })
          .map((element) => `${element.innerText || ''}\n${element.getAttribute('aria-label') || ''}`)
          .join('\n');
        const visibleText = `${document.body.innerText || ''}\n${visibleSemanticText}`;
        return /Server URL|Connect securely|Email or username|Sign in and unlock|Add host/.
          test(visibleText);
      }).catch(() => false);
      if (serverModeVisible) {
        selectedPages.add(page);
        return false;
      }
    }

    await page.waitForTimeout(100);
  }

  return false;
}

module.exports = { selectServerModeIfChooser };
