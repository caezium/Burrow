import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const analyticsPath = path.join(root, 'docs', 'analytics.js')
const placeholder = '__POSTHOG_PROJECT_KEY__'

function runAnalytics({ hostname = 'burrow.computer' } = {}) {
    const listeners = new Map()
    let injectedScript = null
    const firstScript = {
        parentNode: {
            insertBefore(script) {
                injectedScript = script
            },
        },
    }
    const document = {
        addEventListener(name, listener) {
            listeners.set(name, listener)
        },
        createElement() {
            return {}
        },
        getElementsByTagName() {
            return [firstScript]
        },
    }
    const location = {
        hostname,
        href: `https://${hostname}/?private=query#private-fragment`,
        origin: `https://${hostname}`,
        pathname: '/',
    }
    const window = { document, location }
    window.window = window
    const context = vm.createContext({ URL, document, location, window })
    const source = fs.readFileSync(analyticsPath, 'utf8').replace(placeholder, 'phc_Test123')

    vm.runInContext(source, context)

    return { context, injectedScript, listeners }
}

function clickTarget(analyticsKey) {
    return {
        closest(selector) {
            assert.equal(selector, '[data-burrow-analytics]')
            return {
                getAttribute(name) {
                    assert.equal(name, 'data-burrow-analytics')
                    return analyticsKey
                },
            }
        },
    }
}

test('production analytics is cookieless and limited to the approved features', () => {
    const { context, injectedScript } = runAnalytics()
    const [projectKey, config] = context.window.posthog._i[0]

    assert.equal(projectKey, 'phc_Test123')
    assert.equal(injectedScript.src, 'https://us-assets.i.posthog.com/static/array.js')
    assert.equal(config.api_host, 'https://us.i.posthog.com')
    assert.equal(config.ui_host, 'https://us.posthog.com')
    assert.equal(config.cookieless_mode, 'always')
    assert.equal(config.person_profiles, 'never')
    assert.equal(config.autocapture, false)
    assert.equal(config.capture_pageview, true)
    assert.equal(config.capture_pageleave, true)
    assert.equal(config.disable_scroll_properties, false)
    assert.deepEqual(JSON.parse(JSON.stringify(config.capture_performance)), {
        network_timing: false,
        web_vitals: true,
        web_vitals_allowed_metrics: ['CLS', 'INP', 'LCP'],
    })
    assert.equal(config.disable_session_recording, true)
    assert.equal(config.capture_exceptions, false)
    assert.equal(config.capture_dead_clicks, false)
    assert.equal(config.enable_recording_console_log, false)
    assert.equal(config.advanced_disable_flags, true)
    assert.equal(config.respect_dnt, true)
    assert.equal(config.save_campaign_params, false)
    assert.equal(config.mask_personal_data_properties, true)
    assert.equal(config.disable_capture_url_hashes, true)

    const event = config.before_send({
        event: '$pageview',
        properties: {
            $raw_user_agent: 'PrivateBrowser/1.0 exact-build-details',
            $current_url: 'https://burrow.computer/?secret=value#private',
            $initial_current_url: 'https://burrow.computer/releases.html?from=email#v0.11.1',
            $referrer: 'https://search.example/results?q=private#answer',
            $initial_referrer: 'https://news.example/story?user=private#comments',
            $web_vitals_LCP_event: {
                $current_url: 'https://burrow.computer/roadmap.html?private=yes#planned',
                delta: 20,
                entries: [
                    {
                        element: '<img alt="private">',
                        url: 'https://burrow.computer/private.png?token=secret',
                    },
                ],
                id: 'metric-identifier',
                name: 'LCP',
                navigationType: 'navigate',
                rating: 'good',
                timestamp: 123456789,
                value: 123,
            },
        },
    })

    assert.equal(event.properties.$raw_user_agent, 'PrivateBrowser/1.0 exact-build-details')
    assert.equal(event.properties.$current_url, 'https://burrow.computer/')
    assert.equal(event.properties.$initial_current_url, 'https://burrow.computer/releases.html')
    assert.equal(event.properties.$referrer, 'https://search.example/results')
    assert.equal(event.properties.$initial_referrer, 'https://news.example/story')
    assert.deepEqual(JSON.parse(JSON.stringify(event.properties.$web_vitals_LCP_event)), {
        $current_url: 'https://burrow.computer/roadmap.html',
        delta: 20,
        name: 'LCP',
        navigationType: 'navigate',
        rating: 'good',
        value: 123,
    })
})

test('analytics stays inert outside the production hostname', () => {
    const { context, injectedScript, listeners } = runAnalytics({ hostname: 'localhost' })

    assert.equal(context.window.posthog, undefined)
    assert.equal(injectedScript, null)
    assert.equal(listeners.size, 0)
})

test('only fixed download and Homebrew-copy interactions are captured', () => {
    const { context, listeners } = runAnalytics()
    const click = listeners.get('click')
    assert.equal(typeof click, 'function')

    context.window.posthog.length = 0
    click({ target: clickTarget('homebrew.hero') })
    click({ target: clickTarget('download.hero') })
    click({ target: clickTarget('download.landing_mac') })
    click({ target: clickTarget('unknown.future-event') })

    assert.deepEqual(JSON.parse(JSON.stringify(context.window.posthog)), [
        ['capture', 'website_homebrew_copy_clicked', { command: 'install', placement: 'hero' }],
        ['capture', 'website_download_clicked', { destination: 'install_page', placement: 'hero' }],
        ['capture', 'website_download_clicked',
            { destination: 'github_asset', platform: 'macos', placement: 'landing_picker' }],
    ])
})

test('every public HTML page loads analytics and generated pages remain reproducible', () => {
    for (const page of ['index.html', 'releases.html', 'roadmap.html']) {
        const html = fs.readFileSync(path.join(root, 'docs', page), 'utf8')
        assert.equal((html.match(/<script src="\/analytics\.js" defer><\/script>/g) || []).length, 1, page)
    }

    const index = fs.readFileSync(path.join(root, 'docs', 'index.html'), 'utf8')
    for (const marker of [
        'data-burrow-analytics="download.hero"',
        'data-burrow-analytics="download.home"',
        'data-burrow-analytics="download.landing_mac"',
        'data-burrow-analytics="download.landing_windows"',
        'data-burrow-analytics="homebrew.hero"',
        'data-burrow-analytics="homebrew.landing"',
    ]) {
        assert.match(index, new RegExp(marker))
    }

    assert.match(
        fs.readFileSync(path.join(root, 'docs', 'releases.html'), 'utf8'),
        /data-burrow-analytics="download\.changelog"/
    )
    assert.match(
        fs.readFileSync(path.join(root, 'docs', 'roadmap.html'), 'utf8'),
        /data-burrow-analytics="download\.roadmap"/
    )

    execFileSync('python3', ['scripts/site-release.py', '--check'], { cwd: root, stdio: 'pipe' })
})

test('install page explains the manual recovery path for failed in-app updates', () => {
    const install = fs.readFileSync(path.join(root, 'docs', 'install.html'), 'utf8')

    assert.match(install, /If the in-app update can.t complete, quit Burrow/)
    assert.match(install, /replace Burrow\.app in Applications/)
    assert.match(install, /Your settings and history stay on this Mac/)
})

test('deployment injection validates the key and replaces exactly one placeholder', (t) => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'burrow-site-analytics-'))
    t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }))
    const target = path.join(tempDir, 'analytics.js')
    fs.copyFileSync(analyticsPath, target)

    const missing = spawnSync('bash', ['scripts/inject-site-analytics.sh', target], {
        cwd: root,
        encoding: 'utf8',
        env: { ...process.env, POSTHOG_API_KEY: '' },
    })
    assert.notEqual(missing.status, 0)

    const invalid = spawnSync('bash', ['scripts/inject-site-analytics.sh', target], {
        cwd: root,
        encoding: 'utf8',
        env: { ...process.env, POSTHOG_API_KEY: 'not-a-project-key' },
    })
    assert.notEqual(invalid.status, 0)

    const validKey = 'phc_ValidTestKey123'
    const valid = spawnSync('bash', ['scripts/inject-site-analytics.sh', target], {
        cwd: root,
        encoding: 'utf8',
        env: { ...process.env, POSTHOG_API_KEY: validKey },
    })
    assert.equal(valid.status, 0, valid.stderr)
    assert.doesNotMatch(`${valid.stdout}${valid.stderr}`, new RegExp(validKey))

    const deployed = fs.readFileSync(target, 'utf8')
    assert.doesNotMatch(deployed, new RegExp(placeholder))
    assert.match(deployed, new RegExp(validKey))

    const duplicateRun = spawnSync('bash', ['scripts/inject-site-analytics.sh', target], {
        cwd: root,
        encoding: 'utf8',
        env: { ...process.env, POSTHOG_API_KEY: validKey },
    })
    assert.notEqual(duplicateRun.status, 0)
})

test('site deployment fails closed when the analytics key is unavailable', () => {
    const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'deploy-site.yml'), 'utf8')
    const requireKey = workflow.indexOf('- name: Require website analytics key')
    const injectKey = workflow.indexOf('- name: Prepare website assets')
    const deploy = workflow.indexOf('- uses: cloudflare/wrangler-action@')

    assert.notEqual(requireKey, -1)
    assert.notEqual(injectKey, -1)
    assert.ok(requireKey < injectKey)
    assert.ok(injectKey < deploy)
    assert.match(workflow, /HAS_POSTHOG_KEY: \$\{\{ secrets\.POSTHOG_API_KEY != '' \}\}/)
    assert.match(workflow, /run: bash scripts\/prepare-site-assets\.sh \.site-deploy/)
    assert.doesNotMatch(workflow, /cp -R docs/)
    assert.match(workflow, /'scripts\/inject-site-analytics\.sh'/)
    assert.match(workflow, /'scripts\/prepare-site-assets\.sh'/)
    assert.match(workflow, /'scripts\/deploy-site\.sh'/)
    assert.doesNotMatch(workflow, /run 'npx wrangler deploy' locally/)

    const wrangler = fs.readFileSync(path.join(root, 'wrangler.jsonc'), 'utf8')
    assert.match(wrangler, /"directory": "\.\/\.site-deploy"/)
    assert.equal(fs.existsSync(path.join(root, '.site-deploy')), false)
})

test('local deployment stages injected assets without mutating source', (t) => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'burrow-site-deploy-test-'))
    t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }))
    const binDir = path.join(tempDir, 'bin')
    const argsPath = path.join(tempDir, 'npx-args')
    const mockNpx = path.join(binDir, 'npx')
    fs.mkdirSync(binDir)
    fs.writeFileSync(
        mockNpx,
        `#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "wrangler" && "$2" == "deploy" && "$3" == "--assets" && -n "\${4:-}" ]]
grep -qF "$POSTHOG_API_KEY" "$4/analytics.js"
! grep -qF '${placeholder}' "$4/analytics.js"
printf '%s\\n' "$@" > "$BURROW_TEST_ARGS"
`
    )
    fs.chmodSync(mockNpx, 0o755)

    const sourceBefore = fs.readFileSync(analyticsPath, 'utf8')
    const result = spawnSync('bash', ['scripts/deploy-site.sh'], {
        cwd: root,
        encoding: 'utf8',
        env: {
            ...process.env,
            BURROW_TEST_ARGS: argsPath,
            PATH: `${binDir}:${process.env.PATH}`,
            POSTHOG_API_KEY: 'phc_LocalDeployTest123',
        },
    })

    assert.equal(result.status, 0, result.stderr)
    assert.equal(fs.readFileSync(analyticsPath, 'utf8'), sourceBefore)
    const args = fs.readFileSync(argsPath, 'utf8').trim().split('\n')
    assert.deepEqual(args.slice(0, 3), ['wrangler', 'deploy', '--assets'])
    assert.match(args[3], /burrow-site-deploy\..*\/assets$/)
})
