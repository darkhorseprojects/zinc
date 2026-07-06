import { JSX } from "solid-js";

interface IconProps {
  svg: string;
  size?: number;
  class?: string;
  style?: string | JSX.CSSProperties;
}

export function Icon(props: IconProps) {
  const mergedStyle = () => {
    const base: JSX.CSSProperties = {
      width: `${props.size ?? 20}px`,
      height: `${props.size ?? 20}px`,
      display: "inline-flex",
      "align-items": "center",
      "justify-content": "center",
    };

    if (typeof props.style === "object") {
      return { ...base, ...props.style };
    }
    return base;
  };

  return (
    <span
      class={props.class}
      style={mergedStyle()}
      innerHTML={props.svg}
    />
  );
}
