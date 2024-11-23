import Chart from "@/components/Charts/page";
import { Metadata } from "next";
import DefaultLayout from "@/components/Layouts/DefaultLayout";
import React from "react";

export const metadata: Metadata = {
  title: "Companion Intelligence",
  description:
    "Companion Intelligence",
};

const BasicChartPage: React.FC = () => {
  return (
    <DefaultLayout>
      <Chart />
    </DefaultLayout>
  );
};

export default BasicChartPage;
