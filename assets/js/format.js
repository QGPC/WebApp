/* format.js: tidies phone numbers, ZIP codes and state abbreviations when a person leaves a field.
   - Phone: 8175550103, 817-555-0103, 1 817 555 0103 all become (817) 555-0103.
     Anything with letters (for example an extension) is left exactly as typed.
   - ZIP: 760861234 becomes 76086-1234; 76086 stays 76086.
   - State: tx becomes TX.
   Works on any input that is type="tel", has autocomplete="tel" / "postal-code" / "address-level1",
   or says data-fmt="phone" | "zip" | "state". Fields added to the page later work too.
   The database applies the same rules when saving, so a page that skips this still saves tidy data. */
(function () {
  'use strict';
  function digits(s) { return String(s == null ? '' : s).replace(/\D/g, ''); }

  function phone(s) {
    var t = String(s == null ? '' : s).trim();
    if (!t || /[A-Za-z]/.test(t)) return t;
    var d = digits(t);
    if (d.length === 11 && d.charAt(0) === '1') d = d.slice(1);
    if (d.length !== 10) return t;
    return '(' + d.slice(0, 3) + ') ' + d.slice(3, 6) + '-' + d.slice(6);
  }
  function phoneLooksOk(s) { return /^\(\d{3}\) \d{3}-\d{4}$/.test(s) || /[A-Za-z]/.test(s); }

  function zip(s) {
    var t = String(s == null ? '' : s).trim();
    if (!t) return t;
    var d = digits(t);
    if (d.length === 5) return d;
    if (d.length === 9) return d.slice(0, 5) + '-' + d.slice(5);
    return t;
  }

  function state(s) {
    var t = String(s == null ? '' : s).trim();
    return /^[A-Za-z]{2}$/.test(t) ? t.toUpperCase() : t;
  }

  function kindOf(el) {
    var k = el.getAttribute('data-fmt');
    if (k) return k;
    var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
    if (el.type === 'tel' || ac === 'tel') return 'phone';
    if (ac === 'postal-code') return 'zip';
    if (ac === 'address-level1') return 'state';
    return '';
  }

  function hint(el, text) {
    var h = el.parentNode && el.parentNode.querySelector('.fmt-hint[data-for="' + (el.id || '') + '"]');
    if (!text) { if (h) h.parentNode.removeChild(h); el.removeAttribute('aria-invalid'); return; }
    if (!h) {
      h = document.createElement('div');
      h.className = 'fmt-hint';
      h.setAttribute('data-for', el.id || '');
      h.setAttribute('role', 'status');
      h.style.cssText = 'font-size:var(--fs-md);line-height:1.4;margin-top:6px;color:#9A3412';
      el.parentNode.insertBefore(h, el.nextSibling);
    }
    h.textContent = text;
    el.setAttribute('aria-invalid', 'true');
  }

  document.addEventListener('focusout', function (e) {
    var el = e.target;
    if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly) return;
    var k = kindOf(el);
    if (!k) return;
    var before = el.value, after = before;
    if (k === 'phone') after = phone(before);
    else if (k === 'zip') after = zip(before);
    else if (k === 'state') after = state(before);
    if (after !== before) el.value = after;
    var msg = '';
    if (after) {
      if (k === 'phone' && !phoneLooksOk(after)) msg = 'Please check this phone number. It should have 10 digits, like (555) 555-5555.';
      if (k === 'zip' && !/^\d{5}(-\d{4})?$/.test(after)) msg = 'Please check this ZIP code. It should have 5 digits, like 76086.';
      if (k === 'state' && !/^[A-Z]{2}$/.test(after)) msg = 'Please use the two-letter state, like TX.';
    }
    hint(el, msg);
  }, true);

  document.addEventListener('input', function (e) {
    var el = e.target;
    if (el && el.tagName === 'INPUT' && el.getAttribute('aria-invalid') === 'true' && kindOf(el)) hint(el, '');
  }, true);

  window.QGPCFormat = { phone: phone, zip: zip, state: state };
})();
