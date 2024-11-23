import Integrations from "@/components/Dashboard/Integrations";
import { Metadata } from "next";
import DefaultLayout from "@/components/Layouts/DefaultLayout";

export const metadata: Metadata = {
  title:
    "Companion Intelligence",
  description: "Companion Intelligence",
};

export default function Home() {
  return (
    <>
      <DefaultLayout>
        <Integrations />
      </DefaultLayout>
    </>
  );
}
