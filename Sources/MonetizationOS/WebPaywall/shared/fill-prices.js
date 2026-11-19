// Called with [[productId, {"display-price": ..., ...}], ...]. Entries, not an object literal, and a
// prototype-less map, so a product id such as __proto__ cannot change prototypes. Fills every
// [data-mos-product], marks gaps data-mos-price-missing, reveals, and evaluates to {filled, missing}.
(function (entries) {
  var has = Object.prototype.hasOwnProperty, filled = 0, missing = 0, prices = Object.create(null);
  for (var j = 0; j < entries.length; j++) prices[entries[j][0]] = entries[j][1];
  var els = document.querySelectorAll('[data-mos-product]');
  for (var i = 0; i < els.length; i++) {
    var el = els[i], id = el.getAttribute('data-mos-product');
    var field = el.getAttribute('data-mos-price') || 'display-price';
    var p = has.call(prices, id) ? prices[id] : null;
    var v = p && has.call(p, field) ? p[field] : null;
    if (typeof v === 'string') { el.textContent = v; el.removeAttribute('data-mos-price-missing'); filled++; }
    else { el.setAttribute('data-mos-price-missing', ''); missing++; }
  }
  document.documentElement.classList.add('mos-prices-ready');
  return { filled: filled, missing: missing };
})
