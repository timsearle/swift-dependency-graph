const puppeteer = require('./node_modules/puppeteer');

(async () => {
    const browser = await puppeteer.launch({ headless: 'new' });
    const page = await browser.newPage();
    
    page.on('console', msg => console.log('PAGE LOG:', msg.text()));
    page.on('pageerror', err => console.log('PAGE ERROR:', err.message));
    
    await page.goto('file:///tmp/small_test.html', { waitUntil: 'networkidle0', timeout: 30000 });
    
    await new Promise(r => setTimeout(r, 2000));
    
    const result = await page.evaluate(() => {
        const canvas = document.querySelector('#graph canvas');
        return {
            hasCanvas: !!canvas,
            canvasWidth: canvas ? canvas.width : 0,
            canvasHeight: canvas ? canvas.height : 0,
            graphDivWidth: document.getElementById('graph').offsetWidth,
            graphDivHeight: document.getElementById('graph').offsetHeight
        };
    });
    
    console.log('Result:', JSON.stringify(result, null, 2));
    
    await browser.close();
})();
