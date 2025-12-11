const puppeteer = require('./node_modules/puppeteer');
const http = require('http');
const fs = require('fs');

const server = http.createServer((req, res) => {
    const html = fs.readFileSync('/tmp/nav_test.html', 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
});

server.listen(8769, async () => {
    console.log('Server running on port 8769');
    
    const browser = await puppeteer.launch({ headless: 'new' });
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });
    
    page.on('console', msg => console.log('PAGE:', msg.text()));
    page.on('pageerror', err => console.log('ERROR:', err.message));
    
    await page.goto('http://localhost:8769', { waitUntil: 'networkidle0', timeout: 60000 });
    await new Promise(r => setTimeout(r, 5000));
    
    // Take initial screenshot
    await page.screenshot({ path: '/tmp/nav_initial.png' });
    console.log('Initial screenshot saved');
    
    // Check if breadcrumbs exist
    const breadcrumbs = await page.$('#breadcrumbs');
    console.log('Breadcrumbs found:', !!breadcrumbs);
    
    // Check if node-info exists
    const nodeInfo = await page.$('#node-info');
    console.log('Node info panel found:', !!nodeInfo);
    
    await browser.close();
    server.close();
});
