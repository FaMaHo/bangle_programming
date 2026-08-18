// Front-end only placeholder for the join flow.
// Real enrollment-code generation and account linking happen on the
// research team's backend (built separately) — this just demonstrates
// and previews the UI a participant will see.
document.addEventListener("DOMContentLoaded", function () {
  var consentBox = document.getElementById("consent-check");
  var joinBtn = document.getElementById("join-btn");
  var resultCard = document.getElementById("result-card");
  var copyBtn = document.getElementById("copy-code-btn");
  var codeEl = document.getElementById("demo-code");

  if (!joinBtn) return;

  consentBox.addEventListener("change", function () {
    joinBtn.disabled = !consentBox.checked;
  });

  joinBtn.addEventListener("click", function () {
    if (!consentBox.checked) return;
    resultCard.classList.add("show");
    resultCard.scrollIntoView({ behavior: "smooth", block: "center" });
  });

  if (copyBtn) {
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
