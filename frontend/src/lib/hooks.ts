import { useEffect, useRef, useState } from "react";

/**
 * Returns a debounced version of the input value.
 * The returned value only updates after `delay` ms of no changes.
 */
export function useDebounce<T>(value: T, delay: number): T {
    const [debounced, setDebounced] = useState(value);

    useEffect(() => {
        const timer = setTimeout(() => {
            setDebounced(value);
        }, delay);
        return () => {
            clearTimeout(timer);
        };
    }, [value, delay]);

    return debounced;
}

/**
 * Returns an AbortController that is automatically aborted when the
 * component unmounts or when deps change.
 */
export function useAbortController(deps: unknown[]): AbortController {
    const controllerRef = useRef<AbortController>(new AbortController());

    useEffect(() => {
        controllerRef.current = new AbortController();
        return () => {
            controllerRef.current.abort();
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, deps);

    return controllerRef.current;
}
