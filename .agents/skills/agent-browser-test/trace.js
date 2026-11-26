(() => {
  if (window.__agentBrowserTraceInstalled) return;
  window.__agentBrowserTraceInstalled = true;
  window.__agentBrowserLog = window.__agentBrowserLog || [];

  const send = (entry) => {
    try {
      window.__agentBrowserLog.push({ time: Date.now(), ...entry });
    } catch {
      // Logging never breaks the app.
    }
  };

  const selector = (target) => {
    if (!(target instanceof Element)) return null;
    if (target.id) return `#${target.id}`;
    const tag = target.localName;
    const name = target.getAttribute("name");
    return name ? `${tag}[name="${name}"]` : tag;
  };

  window.trace = (name, data = {}) => send({ kind: "app", name, data });

  for (const type of [
    "pointerdown",
    "pointerup",
    "click",
    "keydown",
    "keyup",
    "scroll",
    "focusin",
    "input",
    "submit",
  ]) {
    document.addEventListener(
      type,
      (event) => {
        const target = event.target;
        send({
          kind: "event",
          event: type,
          target: selector(target),
          key: event.key ?? null,
          value: typeof target?.value === "string" ? target.value : null,
          scrollX: window.scrollX,
          scrollY: window.scrollY,
        });
      },
      { capture: true, passive: true }
    );
  }
})();
