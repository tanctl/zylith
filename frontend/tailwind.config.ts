import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        zylith: {
          // Abyssal base - reads as black, blue undertone only on layering
          void: "#050607",
          abyss: "#080a0c",
          deep: "#0a0c0f",
          base: "#0d0f12",

          // Surfaces - blue-black obsidian
          surface: {
            0: "rgba(13, 16, 20, 0.85)",
            1: "rgba(16, 19, 24, 0.88)",
            2: "rgba(19, 22, 28, 0.90)",
            3: "rgba(22, 26, 32, 0.92)",
            modal: "rgba(14, 17, 22, 0.95)",
          },

          // Edges - barely perceptible
          edge: {
            subtle: "rgba(35, 40, 48, 0.4)",
            medium: "rgba(40, 46, 56, 0.5)",
            strong: "rgba(48, 55, 66, 0.6)",
          },

          // Text - high contrast, no color
          text: {
            primary: "#e2e4e8",
            secondary: "#6b7280",
            tertiary: "#4b5058",
          },

          // Accent - internal glow, never border
          accent: {
            inner: "rgba(25, 35, 55, 0.3)",
            glow: "rgba(30, 45, 70, 0.15)",
            focus: "rgba(35, 50, 80, 0.25)",
          },
        },
      },
      borderRadius: {
        none: "0",
        micro: "1px",
        slight: "2px",
      },
      spacing: {
        px: "1px",
        0.5: "2px",
        1: "4px",
        1.5: "6px",
        2: "8px",
        2.5: "10px",
        3: "12px",
        4: "16px",
        5: "20px",
        6: "24px",
      },
      fontFamily: {
        sans: ["'IBM Plex Sans'", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["'IBM Plex Mono'", "ui-monospace", "monospace"],
      },
      fontSize: {
        xs: ["11px", { lineHeight: "16px", letterSpacing: "0.02em" }],
        sm: ["12px", { lineHeight: "18px", letterSpacing: "0.01em" }],
        base: ["13px", { lineHeight: "20px" }],
        lg: ["15px", { lineHeight: "22px", letterSpacing: "-0.01em" }],
        xl: ["18px", { lineHeight: "26px", letterSpacing: "-0.02em" }],
        "2xl": ["24px", { lineHeight: "32px", letterSpacing: "-0.02em" }],
      },
      transitionDuration: {
        400: "400ms",
        600: "600ms",
        800: "800ms",
      },
      transitionTimingFunction: {
        heavy: "cubic-bezier(0.4, 0, 0.1, 1)",
        "heavy-out": "cubic-bezier(0.0, 0, 0.2, 1)",
      },
      keyframes: {
        "fade-in": {
          "0%": { opacity: "0" },
          "100%": { opacity: "1" },
        },
      },
      animation: {
        "fade-in": "fade-in 600ms cubic-bezier(0.4, 0, 0.1, 1)",
      },
    },
  },
  plugins: [],
};

export default config;
