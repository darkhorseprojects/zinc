import { animate, createTimeline, type JSAnimation } from "animejs";

export type AnimationHandle = Pick<JSAnimation, "cancel">;

export function rotateCaretIcon(el: Element | undefined, open: boolean): AnimationHandle | undefined {
  if (!el) return undefined;
  return animate(el, {
    rotate: open ? 180 : 0,
    duration: 160,
    ease: "outQuad",
  });
}

export function revealMenu(el: Element | undefined) {
  if (!el) return;
  const he = el as HTMLElement;
  const fullHeight = he.scrollHeight;
  const itemCount = el.querySelectorAll(".nav-select-item").length;
  
  if (itemCount <= 1) {
    he.style.height = `${fullHeight}px`;
    he.style.opacity = "1";
    he.style.transform = "none";
    return;
  }
  
  he.style.height = "0px";
  he.style.opacity = "0";
  he.style.transformOrigin = "top center";
  
  if (he.parentElement) {
    he.parentElement.style.perspective = "600px";
  }
  
  createTimeline()
    .add(he, {
      height: [0, fullHeight],
      opacity: [0, 1],
      rotateX: [-20, 6, -2, 0],
      scaleX: [0.94, 1.03, 0.99, 1],
      duration: 180,
      ease: "outQuad",
    });
}

export function revealMenuItems(el: Element | undefined) {
  if (!el) return;
  const items = el.querySelectorAll(".nav-select-item");
  const itemCount = items.length;
  
  if (itemCount <= 1) return;
  
  items.forEach((item, i) => {
    const he = item as HTMLElement;
    he.style.opacity = "0";
    createTimeline()
      .add(he, {
        opacity: [0, 1],
        duration: 100,
        delay: i * 5,
        ease: "outQuad",
      });
  });
}

export function spin(el: Element | undefined): AnimationHandle | undefined {
  if (!el) return undefined;
  return animate(el, {
    rotate: "1turn",
    duration: 850,
    loop: true,
    ease: "linear",
  });
}

export function scrollToBottom(el: HTMLElement | undefined): AnimationHandle | undefined {
  if (!el) return undefined;
  return animate(el, {
    scrollTop: el.scrollHeight - el.clientHeight,
    duration: 220,
    ease: "outQuad",
  });
}
