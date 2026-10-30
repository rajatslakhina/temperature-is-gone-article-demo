// Renders the article visuals at 2x: node docs/src/render.js
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch();
  for (const [name, width, height] of [['header', 1600, 840], ['diagram', 1600, 900], ['chart', 1600, 900]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
    await page.goto('file://' + path.join(__dirname, name + '.html'));
    await page.screenshot({ path: path.join(__dirname, '..', name + '.png') });
  }
  await browser.close();
})();
