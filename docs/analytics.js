(function (document, window) {
  'use strict';

  var projectKey = '__POSTHOG_PROJECT_KEY__';
  // Both hosts during the move to burrow.computer; the old one 301s but a
  // cached page can still execute here for a while.
  var SITE_HOSTS = ['burrow.computer', 'burrow.henryzh.dev'];
  if (SITE_HOSTS.indexOf(window.location.hostname) === -1 || !/^phc_[A-Za-z0-9]+$/.test(projectKey)) {
    return;
  }

  function withoutQueryOrFragment(value) {
    if (typeof value !== 'string' || value.length === 0) return value;
    try {
      var url = new URL(value, window.location.origin);
      url.search = '';
      url.hash = '';
      return url.toString();
    } catch (_) {
      return undefined;
    }
  }

  function sanitizeEvent(event) {
    if (!event || !event.properties) return event;

    // Keep PostHog's $raw_user_agent input: cookieless ingestion requires it
    // to derive the rotating hash, then removes it before storing the event.

    ['$current_url', '$initial_current_url', '$referrer', '$initial_referrer'].forEach(function (name) {
      if (!(name in event.properties)) return;
      var sanitized = withoutQueryOrFragment(event.properties[name]);
      if (sanitized) event.properties[name] = sanitized;
      else delete event.properties[name];
    });

    ['CLS', 'INP', 'LCP'].forEach(function (metric) {
      var propertyName = '$web_vitals_' + metric + '_event';
      var detail = event.properties[propertyName];
      if (!detail || typeof detail !== 'object') return;

      var bounded = { name: metric };
      if (typeof detail.value === 'number' && Number.isFinite(detail.value)) bounded.value = detail.value;
      if (typeof detail.delta === 'number' && Number.isFinite(detail.delta)) bounded.delta = detail.delta;
      if (['good', 'needs-improvement', 'poor'].indexOf(detail.rating) !== -1) bounded.rating = detail.rating;
      if (['navigate', 'reload', 'back-forward', 'back-forward-cache', 'prerender', 'restore'].indexOf(detail.navigationType) !== -1) {
        bounded.navigationType = detail.navigationType;
      }
      var sanitized = withoutQueryOrFragment(detail.$current_url);
      if (sanitized) bounded.$current_url = sanitized;
      event.properties[propertyName] = bounded;
    });

    return event;
  }

  // PostHog's official array-loader behavior, reduced to the one queued method
  // this site uses before the async bundle is ready.
  function installPostHogLoader(posthog) {
    if (posthog.__SV || (window.posthog && window.posthog.__loaded)) return;

    function queueMethod(target, methodName) {
      target[methodName] = function () {
        target.push([methodName].concat(Array.prototype.slice.call(arguments, 0)));
      };
    }

    window.posthog = posthog;
    posthog._i = [];
    posthog.init = function (token, config, instanceName) {
      var script = document.createElement('script');
      script.type = 'text/javascript';
      script.crossOrigin = 'anonymous';
      script.async = true;
      script.src = config.api_host.replace('.i.posthog.com', '-assets.i.posthog.com') + '/static/array.js';
      var firstScript = document.getElementsByTagName('script')[0];
      firstScript.parentNode.insertBefore(script, firstScript);

      var instance = posthog;
      if (instanceName !== undefined) instance = posthog[instanceName] = [];
      else instanceName = 'posthog';
      instance.people = instance.people || [];
      instance.toString = function (asPerson) {
        var name = instanceName === 'posthog' ? 'posthog' : 'posthog.' + instanceName;
        if (!asPerson) name += ' (stub)';
        return name;
      };
      instance.people.toString = function () { return instance.toString(true) + '.people (stub)'; };
      queueMethod(instance, 'capture');
      posthog._i.push([token, config, instanceName]);
    };
    posthog.__SV = 1;
  }

  installPostHogLoader(window.posthog || []);

  window.posthog.init(projectKey, {
    api_host: 'https://us.i.posthog.com',
    ui_host: 'https://us.posthog.com',
    defaults: '2026-05-30',
    cookieless_mode: 'always',
    person_profiles: 'never',
    respect_dnt: true,
    autocapture: false,
    capture_pageview: true,
    capture_pageleave: true,
    disable_scroll_properties: false,
    capture_performance: {
      web_vitals: true,
      web_vitals_allowed_metrics: ['CLS', 'INP', 'LCP'],
      network_timing: false
    },
    disable_session_recording: true,
    capture_exceptions: false,
    capture_dead_clicks: false,
    enable_recording_console_log: false,
    advanced_disable_flags: true,
    save_campaign_params: false,
    mask_personal_data_properties: true,
    disable_capture_url_hashes: true,
    before_send: sanitizeEvent
  });

  var interactions = {
    // install command copies
    'homebrew.hero': ['website_homebrew_copy_clicked', { command: 'install', placement: 'hero' }],
    'homebrew.landing': ['website_homebrew_copy_clicked', { command: 'install', placement: 'landing_picker' }],
    'homebrew.install': ['website_homebrew_copy_clicked', { command: 'install', placement: 'install_page' }],
    // download clicks, by where the visitor was standing
    'download.hero': ['website_download_clicked', { destination: 'install_page', placement: 'hero' }],
    'download.navigation': ['website_download_clicked', { destination: 'install_page', placement: 'navigation' }],
    'download.home': ['website_download_clicked', { destination: 'install_page', placement: 'navigation' }],
    'download.landing_mac': ['website_download_clicked', { destination: 'github_asset', platform: 'macos', placement: 'landing_picker' }],
    'download.landing_windows': ['website_download_clicked', { destination: 'github_asset', platform: 'windows', placement: 'landing_picker' }],
    'download.install_mac': ['website_download_clicked', { destination: 'github_asset', platform: 'macos', placement: 'install_page' }],
    'download.install_windows': ['website_download_clicked', { destination: 'github_asset', platform: 'windows', placement: 'install_page' }],
    'download.windows': ['website_download_clicked', { destination: 'github_asset', platform: 'windows', placement: 'legacy' }],
    // the nav download button, labelled by which page it was clicked from
    'download.install': ['website_download_clicked', { destination: 'install_page', placement: 'nav_install' }],
    'download.docs': ['website_download_clicked', { destination: 'install_page', placement: 'nav_docs' }],
    'download.compare': ['website_download_clicked', { destination: 'install_page', placement: 'nav_compare' }],
    'download.blog': ['website_download_clicked', { destination: 'install_page', placement: 'nav_blog' }],
    'download.changelog': ['website_download_clicked', { destination: 'install_page', placement: 'nav_changelog' }],
    'download.roadmap': ['website_download_clicked', { destination: 'install_page', placement: 'nav_roadmap' }]
  };
  document.addEventListener('click', function (event) {
    if (!event.target || typeof event.target.closest !== 'function') return;
    var control = event.target.closest('[data-burrow-analytics]');
    if (!control) return;
    var interaction = interactions[control.getAttribute('data-burrow-analytics')];
    if (!interaction) return;
    window.posthog.capture(interaction[0], interaction[1]);
  });
}(document, window));
