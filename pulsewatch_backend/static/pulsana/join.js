// Consent checkbox gates the submit button; the code below (when present)
// is real, server-issued in the POST response to /join.
document.addEventListener("DOMContentLoaded", function () {
  var consentBox = document.getElementById("consent-check");
  var joinBtn = document.getElementById("join-btn");
  var copyBtn = document.getElementById("copy-code-btn");
  var codeEl = document.getElementById("enrollment-code");

  if (consentBox && joinBtn) {
    consentBox.addEventListener("change", function () {
      joinBtn.disabled = !consentBox.checked;
    });
  }

  if (copyBtn && codeEl) {
    copyBtn.addEventListener("click", function () {
      var text = codeEl.textContent.trim();
      var dict = window.I18N[window.PulsanaI18n.get()];
      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(function () {
          copyBtn.textContent = dict.join_copied;
          setTimeout(function () {
            copyBtn.textContent = dict.join_copy_btn;
          }, 1800);
        });
      }
    });
  }
});
