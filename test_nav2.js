const puppeteer = require('./node_modules/puppeteer');
const http = require('http');
const fs = require('fs');

const server = http.createServer((req, res) => {
    const html = fs.readFileSync('/tmp/nav_test.html', 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
});

server.listen(8770, async () => {
    console.log('Server running on port 8770');
    
    const browser = await puppeteer.launch({ headless: 'new' });
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });
    
    page.on('console', msg => console.log('PAGE:', msg.text()));
    page.on('pageerror', err => console.log('ERROR:', err.message));
    
    await page.goto('http://localhost:8770', { waitUntil: 'networkidle0', timeout: 60000 });
    await new Promise(r => setTimeout(r, 5000));
    
    // Take initial screenshot
    await page.screenshot({ path: '/tmp/nav_initial2.png' });
    console.log('Initial screenshot saved');
    
    // Check breadcrumbs text
    const breadcrumbText = await page.$eval('#breadcrumbs', el => el.textContent);
    console.log('Breadcrumb text:', breadcrumbText);
    
    // Simulate double-click on a node (center of graph area)
    await page.mouse.click(450, 450, { clickCount: 2 });
    await new Promise(r => setTimeout(r, 3000));
    
    // Take screenshot after navigation
    await page.screenshot({ path: '/tmp/nav_after_click.png' });
    console.log('After click screenshot saved');
    
    // Check updated breadcrumbs
    const newBreadcrumbText = await page.$eval('#breadcrumbs', el => el.textContent);
    console.log('New breadcrumb text:', newBreadcrumbText);
    
    await browser.close();
    server.close();
});
