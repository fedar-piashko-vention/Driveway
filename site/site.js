// Copy buttons: each button names the <code> element it copies in data-copy.
document.querySelectorAll("button[data-copy]").forEach((button) => {
  const label = button.textContent;
  let timer;

  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    let copied = false;
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch {
      // Older browsers and non-HTTPS pages: fall back to a hidden textarea.
      const area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      copied = document.execCommand("copy");
      area.remove();
    }

    button.textContent = copied ? "Copied" : "Press ⌘C";
    button.classList.toggle("copied", copied);
    document.getElementById("copy-status").textContent = copied
      ? "Command copied. Paste it into Terminal."
      : "Couldn't copy. The command is selected: press Command C.";
    if (!copied) {
      const range = document.createRange();
      range.selectNodeContents(document.getElementById(button.dataset.copy));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
    }
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.textContent = label;
      button.classList.remove("copied");
    }, 2000);
  });
});
