// Evaluates to the distinct data-mos-product values on the page, as an array.
(function () {
  var has = Object.prototype.hasOwnProperty, seen = {}, ids = [];
  var els = document.querySelectorAll('[data-mos-product]');
  for (var i = 0; i < els.length; i++) {
    var id = els[i].getAttribute('data-mos-product');
    if (id && !has.call(seen, id)) { seen[id] = 1; ids.push(id); }
  }
  return ids;
})()
