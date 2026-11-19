// Reveals priced elements after 2 s if filling never finishes, so the server's fallback text shows,
// and turns a click on [data-mos-redeem] into a mos://redeem navigation.
(function () {
  setTimeout(function () { document.documentElement.classList.add('mos-prices-ready'); }, 2000);
  document.addEventListener('click', function (e) {
    var t = e.target;
    var el = t && t.closest ? t.closest('[data-mos-redeem]') : null;
    if (!el) return;
    var token = el.getAttribute('data-mos-redeem');
    if (!token) return;
    e.preventDefault();
    location.href = 'mos://redeem?token=' + encodeURIComponent(token);
  }, true);
})();
