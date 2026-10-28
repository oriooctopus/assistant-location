// Reward illustrations, keyed by rewards.art. artSvg() throws on an unknown key.
(function () {
  var ART = {
    upgrading: {
      big: '<svg viewBox="0 0 200 160"><text x="100" y="40" text-anchor="middle" font-family="Archivo Black" font-size="18" fill="#fff">UPGRADING</text>' +
        '<rect x="20" y="62" width="160" height="34" rx="17" fill="none" stroke="#fff" stroke-width="4"/><rect x="28" y="70" width="104" height="18" rx="9" fill="#ff2e88"/>' +
        '<g font-family="Archivo Black" font-size="16" text-anchor="middle"><text x="36" y="124" fill="#555">A</text><text x="78" y="124" fill="#555">B</text><text x="120" y="124" fill="#ff2e88">C</text><text x="162" y="124" fill="#fff">DD</text></g>' +
        '<text x="100" y="150" text-anchor="middle" font-family="Space Grotesk" font-weight="700" font-size="13" fill="#bdbdbd">DO NOT TURN OFF</text></svg>',
      thumb: '<svg viewBox="0 0 52 52"><rect x="5" y="9" width="42" height="14" rx="7" fill="none" stroke="#fff" stroke-width="2.5"/><rect x="8.5" y="12.5" width="26" height="7" rx="3.5" fill="#ff2e88"/>' +
        '<text x="26" y="43" text-anchor="middle" font-family="Archivo Black" font-size="19" fill="#fff">DD</text></svg>'
    }
  };
  window.artSvg = function (key, kind) {
    if (!ART[key]) throw new Error('Unknown reward art: ' + key);
    return ART[key][kind];
  };
})();
