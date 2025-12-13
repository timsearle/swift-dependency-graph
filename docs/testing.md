# Testing

```bash
swift test
```

Tests cover:
- Package.resolved parsing (v1 and v2)
- pbxproj parsing for Swift packages and targets
- transient dependency detection and filtering
- output format contracts

Optional (HTML dev):

```bash
npm install puppeteer
node test_script.js
```
