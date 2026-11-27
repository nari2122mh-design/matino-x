// MATINO X console - key handling (kept external so strict CSP stays intact).
function makeKey() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let out = "baypassx-";
  for (let g = 0; g < 3; g++) {
    if (g) out += "-";
    for (let i = 0; i < 4; i++) out += chars[Math.floor(Math.random() * chars.length)];
  }
  return out;
}

document.addEventListener("DOMContentLoaded", function () {
  const input = document.getElementById("keyInput");
  const gen = document.getElementById("genKey");
  const picker = document.getElementById("keyPicker");

  if (input && !input.value) input.value = makeKey();
  if (gen && input) {
    gen.addEventListener("click", function () {
      input.value = makeKey();
      if (picker) picker.value = "";
    });
  }
  if (picker && input) {
    picker.addEventListener("change", function () {
      if (picker.value) input.value = picker.value;
    });
  }
});
